//! `iets build`: evaluate to derivations and build them through a daemon.
//!
//! A repeated build is answered from the tracing cache: the entry holds the
//! roots and the drv and source tables, so a hit plans and builds without
//! evaluating.

const std = @import("std");
const Io = std.Io;
const Writer = Io.Writer;
const Allocator = std.mem.Allocator;
const Diag = @import("../diag.zig").Diag;
const Session = @import("../session.zig").Session;
const log = @import("../log.zig");
const errors = @import("../errors.zig");
const Evaluator = @import("../eval/Evaluator.zig");
const provenance = @import("../provenance.zig");
const Provenance = provenance.Provenance;
const remote = @import("../remote.zig");
const plan = remote.plan;
const Plan = plan.Plan;
const worker = remote.worker;
const StorePath = @import("../store/path.zig").StorePath;
const locate = @import("../store/locate.zig");
const api = @import("../api.zig");
const EvalArgs = api.EvalArgs;
const apibuild = api.build;
const installable = api.installable;
const api_render = api.render;
const build = @import("../build.zig");
const dispatch = build.dispatch;
const Target = dispatch.Target;
const Outcome = dispatch.Outcome;
const backend = build.backend;
const fixhash = build.fixhash;
const derivation = @import("../builtins/derivation.zig");
const cli = @import("../cli.zig");
const args_mod = @import("args.zig");
const Args = args_mod.Args;
const out = @import("render.zig");
const devenv = @import("devenv.zig");
const Output = @import("../build/event.zig").Output;

const BuildArgs = struct {
    url: ?[]const u8 = null,
    timings: bool = false,
    no_build: bool = false,
    dry_run: bool = false,
    json: bool = false,
    keep_going: bool = false,
    fetch_to: ?[]const u8 = null,
    out_link: ?[]const u8 = null,
    outputs: std.ArrayList([]const u8) = .empty,
    sources: locate.Overrides = .empty,
    /// What names this run's roots in the roots store (`devenv.keepOutputs`).
    root_key: []const []const u8 = &.{},
};

/// `iets build`: evaluate to derivations and ship their closure from
/// memory, or (legacy) take a `.drv` path and read its closure from
/// `/nix/store`. A fixed-output build that fails on its hash gets it fixed
/// per the `fix-hashes` setting.
pub fn cmd(c: *const cli.Ctx, argv: []const []const u8) u8 {
    const s = c.s;
    s.log.command = "build";
    var ask = switch (s.settings.fix_hashes) {
        .never => return buildOnce(c, argv),
        .ask => if (!fixhash.interactive(&s.log)) return buildOnce(c, argv) else true,
        .always => false,
    };
    const arena = c.init.arena.allocator();
    var wrote: std.ArrayList([]const u8) = .empty;
    while (true) {
        const code = buildOnce(c, argv);
        const mismatches = s.log.takeMismatches() catch return code;
        defer s.log.freePairs(mismatches);
        if (code == 0 or mismatches.len == 0) return code;
        const files = localFiles(c, argv);
        var fixed = false;
        for (mismatches) |m| {
            for (wrote.items) |w| if (std.mem.eql(u8, w, m.specified)) {
                s.log.textLine(std.fmt.allocPrint(arena, "warning: fix-hashes: the hash changed again, from '{s}' to '{s}': the output is not reproducible", .{ m.specified, m.got }) catch return code);
                return code;
            };
            var d: Diag = .init(s.gpa);
            defer d.deinit();
            const fix = fixhash.locate(arena, s.io, files, m.specified, m.got, &d) catch {
                s.log.textLine(std.fmt.allocPrint(arena, "warning: fix-hashes: {s}", .{d.message()}) catch return code);
                continue;
            };
            if (ask) switch (fixhash.prompt(&s.log, s.io, &fix)) {
                .no => continue,
                .all => ask = false,
                .yes => {},
            };
            fix.write(s.gpa, s.io, &d) catch {
                s.log.textLine(std.fmt.allocPrint(arena, "warning: fix-hashes: {s}", .{d.message()}) catch return code);
                continue;
            };
            const pos = std.fmt.allocPrint(arena, "{f}", .{&fix}) catch return code;
            s.log.fixed(pos, fix.at, fix.old, fix.new);
            wrote.append(arena, arena.dupe(u8, m.got) catch return code) catch return code;
            fixed = true;
        }
        if (!fixed) return code;
    }
}

const Parsed = struct { b: BuildArgs, a: EvalArgs };

fn parse(a: *Args) args_mod.Error!Parsed {
    var b: BuildArgs = .{};
    var rest: std.ArrayList([]const u8) = .empty;
    const argv = a.argv;
    while (a.i < argv.len) : (a.i += 1) {
        const x = argv[a.i];
        const flag = std.meta.stringToEnum(enum {
            @"--builder",
            @"--timings",
            @"--no-build",
            @"--dry-run",
            @"--json",
            @"-k",
            @"--keep-going",
            @"--fetch-to",
            @"-o",
            @"--out-link",
            @"--out",
            @"--source",
        }, x) orelse {
            try rest.append(a.arena, x);
            continue;
        };
        switch (flag) {
            .@"--builder" => b.url = try a.next(x),
            .@"--timings" => b.timings = true,
            .@"--no-build" => b.no_build = true,
            .@"--dry-run" => b.dry_run = true,
            .@"--json" => b.json = true,
            .@"-k", .@"--keep-going" => b.keep_going = true,
            .@"--fetch-to" => b.fetch_to = try a.next(x),
            .@"-o", .@"--out-link" => b.out_link = try a.next(x),
            .@"--out" => try b.outputs.append(a.arena, try a.next(x)),
            .@"--source" => {
                const spec = try a.next(x);
                const i = std.mem.indexOfScalar(u8, spec, '=') orelse return a.fail("--source wants STOREPATH=LOCAL, got '{s}'", .{spec});
                try b.sources.put(a.arena, spec[0..i], spec[i + 1 ..]);
            },
        }
    }
    const p = try args_mod.parseEvalArgs(a, rest.items);
    const all = try installables(a.arena, &p.eval);
    b.root_key = try rootKey(a.arena, a.s.io, all);
    return .{ .b = b, .a = p.eval };
}

/// One `EvalArgs` per installable, sorted and without repeats, so every
/// order of the same set is one job.
fn installables(arena: Allocator, a: *const EvalArgs) ![]EvalArgs {
    var all: std.ArrayList(EvalArgs) = .empty;
    var inputs: std.ArrayList(api.Input) = .empty;
    try inputs.appendSlice(arena, a.more);
    if (a.input) |i| try inputs.append(arena, i);
    for (inputs.items) |i| {
        var one = a.*;
        one.more = &.{};
        one.input = i;
        try all.append(arena, one);
    }
    if (all.items.len == 0) try all.append(arena, a.*);
    const Keyed = struct { key: []const u8, a: EvalArgs };
    const keyed = try arena.alloc(Keyed, all.items.len);
    for (all.items, keyed) |x, *k| k.* = .{ .key = try label(arena, &x), .a = x };
    std.sort.insertion(Keyed, keyed, {}, struct {
        fn lt(_: void, x: Keyed, y: Keyed) bool {
            return std.mem.lessThan(u8, x.key, y.key);
        }
    }.lt);
    var n: usize = 0;
    for (keyed) |k| {
        if (n > 0 and std.mem.eql(u8, keyed[n - 1].key, k.key)) continue;
        keyed[n] = k;
        n += 1;
    }
    const res = try arena.alloc(EvalArgs, n);
    for (keyed[0..n], res) |k, *r| r.* = k.a;
    return res;
}

fn label(arena: Allocator, a: *const EvalArgs) ![]const u8 {
    const in = if (a.input) |i| i.text() else "";
    return std.fmt.allocPrint(arena, "{s}\x00{s}", .{ in, a.attr orelse "" });
}

/// What names this run's roots: the tag, the working directory and the
/// installables, so two projects keep two sets of roots and the same command
/// replaces its own in place. A drv path would not: every edit would leave
/// the previous root behind for the TTL to sweep.
fn rootKey(arena: Allocator, io: Io, all: []const EvalArgs) ![]const []const u8 {
    var key: std.ArrayList([]const u8) = .empty;
    try key.append(arena, "build");
    try key.append(arena, std.process.currentPathAlloc(io, arena) catch "/");
    for (all) |*a| try key.append(arena, try label(arena, a));
    return key.items;
}

/// The local files the evaluation of `argv` parses, from a fresh
/// evaluation.
fn localFiles(c: *const cli.Ctx, argv: []const []const u8) []const []const u8 {
    const arena = c.init.arena.allocator();
    var a: Args = .{ .s = c.s, .arena = arena, .cmd = "build", .argv = argv };
    const p = parse(&a) catch return &.{};
    const all = installables(arena, &p.a) catch return &.{};
    for (all) |*x| x.no_tracing_cache = true;
    const Ctx = struct {
        c: *const cli.Ctx,
        all: []const EvalArgs,
        files: []const []const u8 = &.{},
        fn f(x: *@This(), ev: *Evaluator) !u8 {
            const ar = x.c.init.arena.allocator();
            _ = resolveAll(x.c, ev, ar, x.all) catch {};
            x.files = try fixhash.localFiles(ar, ev, x.c.s.settings.source_map);
            return 0;
        }
    };
    var ctx: Ctx = .{ .c = c, .all = all };
    const run: api.run.Run = .{ .s = c.s, .init = c.init, .args = &all[0] };
    _ = run.go(&ctx, Ctx.f);
    return ctx.files;
}

fn buildOnce(c: *const cli.Ctx, argv: []const []const u8) u8 {
    const arena = c.init.arena.allocator();
    var a: Args = .{ .s = c.s, .arena = arena, .cmd = "build", .argv = argv };
    var p = parse(&a) catch |e| return a.report(e);
    if (p.a.more.len == 0) if (p.a.input) |i| if (i == .file and std.mem.endsWith(u8, i.file, ".drv"))
        return buildDrvFile(c, &p.b, i.file);
    const all = installables(arena, &p.a) catch return 1;
    for (all) |*x| x.timings = x.timings or p.b.timings;
    const t0 = now(c.s.io);
    // only flakes can be named in the key by their directory
    const tcache = blk: {
        if (all.len == 1) break :blk api.cache.open(c.s, c.init, &all[0], "build", &.{}) catch null;
        var more: std.ArrayList([]const u8) = .empty;
        for (all[1..]) |*x| switch (x.input orelse break :blk null) {
            .flake => |f| more.append(arena, f) catch break :blk null,
            else => break :blk null,
        };
        if (all[0].input == null or all[0].input.? != .flake) break :blk null;
        break :blk api.cache.open(c.s, c.init, &all[0], "build", more.items) catch null;
    };
    defer if (tcache) |tc| tc.deinit();
    if (tcache) |tc| if (buildHit(c, tc, &p.b, all[0].cache_dir, t0)) |code| return code;
    const Ctx = struct {
        c: *const cli.Ctx,
        b: *BuildArgs,
        all: []const EvalArgs,
        t0: u64,
        cache: ?*api.cache.Cache,
        fn f(x: *@This(), ev: *Evaluator) !u8 {
            return buildEval(x.c, ev, x.b, x.all, x.t0, x.cache);
        }
    };
    var ctx: Ctx = .{ .c = c, .b = &p.b, .all = all, .t0 = t0, .cache = tcache };
    // parallel: eval and build run as the main fiber
    const run: api.run.Run = .{ .s = c.s, .init = c.init, .args = &all[0], .cache = tcache };
    return run.go(&ctx, Ctx.f);
}

/// The build a valid entry describes, with no evaluation: its roots, and
/// the derivations and sources the plan reads. Null is a miss, and the run
/// evaluates.
fn buildHit(c: *const cli.Ctx, tc: *api.cache.Cache, b: *BuildArgs, cache_dir: ?[]const u8, t0: u64) ?u8 {
    const s = c.s;
    const arena = c.init.arena.allocator();
    // the input store the read set's `Input` observations and the source
    // table's fetched trees are in
    const root = (@import("../cachefs.zig").root(arena, c.init.environ_map, cache_dir orelse s.settings.cache_dir) catch null) orelse null;
    var inputs: @import("../treestore.zig").Store = .init(s.gpa, s.io, if (root) |r| (@import("../treestore.zig").locate(arena, r) catch null) else null);
    defer inputs.deinit();
    tc.inputs = .{ .ctx = &inputs, .has = struct {
        fn has(ctx: *anyopaque, name: []const u8, version: u8) bool {
            const st: *@import("../treestore.zig").Store = @ptrCast(@alignCast(ctx));
            return st.has(name, version);
        }
    }.has };
    if (!(tc.lookup() catch return null)) return null;
    if (tc.replayedNixConfig()) s.ignored.nixConfigSeen();
    const wire = @import("../trace.zig").wire;
    const decoded = blk: {
        const rb = tc.part(.result) orelse break :blk null;
        const db = tc.part(.drvs) orelse break :blk null;
        const sb = tc.part(.sources) orelse break :blk null;
        const roots = (wire.decodeRoots(arena, rb) catch break :blk null) orelse break :blk null;
        const tables = (api.cache.Tables.decode(arena, db, sb, &inputs) catch break :blk null) orelse break :blk null;
        break :blk .{ roots, tables };
    };
    const roots_w, var tables = decoded orelse {
        tc.discardTables();
        return null;
    };
    tc.replayWarnings() catch {};
    if (b.timings) {
        const secs = backend.secs(now(s.io) - t0);
        s.log.errln(std.fmt.allocPrint(arena, "eval: skipped, {d} derivations and {d} sources from the cache, {f}s", .{ tables.drvs.count(), tables.source_count, secs }) catch "eval: skipped");
    }
    const roots = arena.alloc(installable.DrvRoot, roots_w.len) catch return 1;
    for (roots_w, roots) |r, *o| o.* = .{ .drv = r.drv, .output = r.output };
    const t = api.buildTargets(arena, b.outputs.items, roots) catch return 1;
    var prov: Provenance = .fromMap(tables.sourceMap(s.gpa, arena, s.settings.source_map) catch return 1, s.settings.provenance);
    defer prov.deinit();
    const Names = struct {
        t: *const api.cache.Tables,
        fn name(n: @This(), r: *const StorePath) []const u8 {
            return n.t.attrs.get(r.*) orelse provenance.drvName(r.baseName());
        }
    };
    return buildRoots(c, b, t.paths, t.outputs, tables.inputs(), &prov, Names{ .t = &tables }, Names.name);
}

fn now(io: Io) u64 {
    return @intCast(Io.Clock.awake.now(io).toNanoseconds());
}

/// The roots of every installable.
fn resolveAll(c: *const cli.Ctx, ev: *Evaluator, arena: Allocator, all: []const EvalArgs) Evaluator.Error![]const installable.DrvRoot {
    var roots: std.ArrayList(installable.DrvRoot) = .empty;
    for (all) |*a| {
        const act = api.evaluating(c.s, arena, a) catch return error.OutOfMemory;
        defer act.end();
        try resolve(c, ev, arena, a, &roots);
    }
    return roots.items;
}

/// The roots of the installable, each named by the attribute it was reached
/// by: the walk names a tree's members, the installable names the rest.
fn resolve(c: *const cli.Ctx, ev: *Evaluator, arena: Allocator, a: *const EvalArgs, roots: *std.ArrayList(installable.DrvRoot)) Evaluator.Error!void {
    const target = a.attr orelse if (a.input) |i| switch (i) {
        .flake => |f| if (std.mem.indexOfScalar(u8, f, '#')) |h| f[h + 1 ..] else "",
        else => "",
    } else "";
    const cwd = std.process.currentPathAlloc(c.init.io, arena) catch "/";
    const v = try api.evaluate(ev, arena, a, cwd);
    const auto = try api.autoArgs(ev, arena, a.args);
    const start = roots.items.len;
    try installable.rootsOf(ev, arena, v, auto, target, roots);
    for (roots.items[start..]) |r| try derivation.setAttr(ev, r.drv.baseName(), target);
}

fn buildEval(c: *const cli.Ctx, ev: *Evaluator, b: *BuildArgs, all: []const EvalArgs, t0: u64, tcache: ?*api.cache.Cache) !u8 {
    const s = c.s;
    const arena = c.init.arena.allocator();
    if (all[0].input == null) {
        var a: Args = .{ .s = s, .arena = arena, .cmd = "build", .argv = &.{} };
        return a.report(a.fail("nothing to evaluate: give -E EXPR or FILE", .{}));
    }
    const roots = try resolveAll(c, ev, arena, all);
    var inputs: apibuild.EvalInputs = .init(ev);
    defer inputs.deinit();
    if (b.timings) {
        const secs = backend.secs(now(s.io) - t0);
        s.log.errln(try std.fmt.allocPrint(arena, "eval: {d} derivations, {d} sources, {f}s", .{ ev.shared.drv.nr_derivations, inputs.sourceCount(), secs }));
    }
    if (tcache) |tc| try api.cache.writeBuild(tc, s, ev, roots);
    const t = try api.buildTargets(arena, b.outputs.items, roots);
    var prov = try apibuild.snapshot(s, arena, ev);
    defer prov.deinit();
    const Names = struct {
        ev: *Evaluator,
        fn name(n: @This(), r: *const StorePath) []const u8 {
            n.ev.shared.drv_lock.lock(n.ev);
            defer n.ev.shared.drv_lock.unlock(n.ev);
            if (n.ev.shared.drv.table.get(r.baseName())) |i| if (i.attr) |x| return x;
            return provenance.drvName(r.baseName());
        }
    };
    return buildRoots(c, b, t.paths, t.outputs, inputs.inputs(), &prov, Names{ .ev = ev }, Names.name);
}

/// Legacy mode: `DRV` is a `.drv` store path, or a copy of the file named
/// `<hash>-<name>.drv`; its closure is read from `/nix/store`.
fn buildDrvFile(c: *const cli.Ctx, b: *BuildArgs, root_arg: []const u8) u8 {
    const s = c.s;
    const arena = c.init.arena.allocator();
    var d: Diag = .init(s.gpa);
    defer d.deinit();
    const root = StorePath.fromBaseName(std.fs.path.basename(root_arg), &d) catch |e| return report(s, &d, e);
    if (!root.isDerivation()) {
        const msg = std.fmt.allocPrint(arena, "'{f}' is not a derivation", .{&root}) catch "not a derivation";
        const r: log.Report = .{ .code = "store", .raw = msg };
        return r.emit(&s.log);
    }
    var table: apibuild.DrvTable = .init(s.gpa);
    defer table.deinit();
    // the root may be a copy outside the store; its inputs are read from /nix/store
    const text = Io.Dir.cwd().readFileAlloc(s.io, root_arg, s.gpa, .unlimited) catch |e| {
        const msg = std.fmt.allocPrint(arena, "cannot read derivation '{s}': {s}", .{ root_arg, errors.ioText(e) }) catch "cannot read derivation";
        const r: log.Report = .{ .code = "io", .raw = msg };
        return r.emit(&s.log);
    };
    defer s.gpa.free(text);
    table.add(root, text, &d) catch |e| {
        const msg = std.fmt.allocPrint(arena, "cannot read derivation '{s}': {s}", .{ root_arg, d.message() }) catch "cannot read derivation";
        const r: log.Report = .{ .code = errors.code(e), .raw = msg };
        return r.emit(&s.log);
    };
    var prov: Provenance = .fromMap(.init(s.gpa), s.settings.provenance);
    defer prov.deinit();
    const NoName = struct {
        fn name(_: void, r: *const StorePath) []const u8 {
            return provenance.drvName(r.baseName());
        }
    };
    return buildRoots(c, b, &.{root}, b.outputs.items, table.inputs(), &prov, {}, NoName.name);
}

/// An error outside the evaluator, reported with its code; the exit code.
fn report(s: *Session, d: *const Diag, e: anyerror) u8 {
    const r = errors.report(e, d);
    return r.emit(&s.log);
}

fn buildRoots(c: *const cli.Ctx, b: *BuildArgs, roots: []const StorePath, outputs: []const []const u8, inputs: plan.Inputs, prov: *const Provenance, name_ctx: anytype, comptime name: fn (@TypeOf(name_ctx), *const StorePath) []const u8) u8 {
    const s = c.s;
    if (roots.len == 0) return noOutput(s, "nothing to build: the expression has no derivation in it");
    const arena = c.init.arena.allocator();
    var d: Diag = .init(s.gpa);
    defer d.deinit();
    const env = c.init.environ_map;
    const transport = arena.create(worker.Transport) catch return 1;
    transport.* = apibuild.transport(arena, s, env, b.url, &d) catch |e| return report(s, &d, e);
    const t0 = now(s.io);
    var p = plan.plan(s.gpa, s.io, roots, inputs, &d) catch |e| return report(s, &d, e);
    const plan_time = now(s.io) - t0;
    if (b.timings and p.store_drvs > 0)
        s.log.errln(std.fmt.allocPrint(arena, "plan: {d} drvs not from this eval, read from /nix/store", .{p.store_drvs}) catch "");
    var opts: worker.Options = .default();
    // one root is one question, and its first failure answers it; several
    // roots are several questions, and each one gets its verdict
    opts.keep_going = b.keep_going or roots.len > 1;
    const cx: backend.Context = .{ .gpa = s.gpa, .io = s.io, .env = env, .log = .of(&s.log) };
    const dp = dispatch.Dispatcher.open(cx, &s.log, transport, opts, prov, .detect(&s.log), &d) catch |e| {
        p.deinit();
        return report(s, &d, e);
    };
    var x: apibuild.Dispatch = .{
        .gpa = s.gpa,
        .io = s.io,
        .plan = p,
        .overrides = b.sources,
        .nix = .{ .io = s.io, .env = s.env, .nix_bin_dir = s.settings.nix_bin_dir },
        .d = dp,
    };
    defer x.deinit();

    if (b.no_build) {
        x.uploadOnly(roots, &d) catch |e| return report(s, &d, e);
        timings(s, b, &x, plan_time);
        return 0;
    }
    const targets = arena.alloc(Target, roots.len) catch return 1;
    // the bare attribute: the dispatcher adds the position, once
    // by pointer: a name may be a slice of the root itself (`drvName`)
    for (roots, targets) |*r, *t| t.* = .{ .attr = name(name_ctx, r), .drv = r.*, .outputs = outputs };
    if (b.dry_run) {
        const m = x.missing(arena, targets, &d) catch |e| return report(s, &d, e);
        return printMissing(s, arena, m, &x.plan, b.json);
    }
    const outcomes = x.submit(targets, &d) catch |e| return report(s, &d, e);
    if (b.fetch_to) |dir| {
        for (outcomes) |o| for (o.outputs) |op| x.d.fetch(op.path, dir, &d) catch |e| return report(s, &d, e);
    } else if (b.out_link) |prefix| {
        const links = outLinks(arena, s.io, prefix, outcomes) catch return 1;
        x.d.outLinks(links, &d) catch |e| return report(s, &d, e);
    } else {
        // the caller reads these paths off stdout and uses them afterwards,
        // so a collection in between must not take them. `--fetch-to`
        // already has the bytes outside the store and keeps no root here.
        var keep: std.ArrayList([2][]const u8) = .empty;
        for (outcomes) |o| for (o.outputs) |op| keep.append(arena, .{ std.fmt.allocPrint(arena, "{s}!{s}", .{ o.attr, op.name }) catch return 1, op.path }) catch return 1;
        const dc: devenv.Ctx = .{ .s = s, .env_map = env, .log = .of(&s.log) };
        devenv.keepOutputs(&dc, transport, b.root_key, keep.items);
    }
    timings(s, b, &x, plan_time);
    const rep: api_render.Outcomes = .{ .items = outcomes };
    if (outcomes.len > 1) out.built(s, arena, rep) catch {};
    out.emit(s, arena, rep, b.json) catch |e| {
        const r: log.Report = .{ .code = "io", .raw = std.fmt.allocPrint(arena, "write of the output: {s}", .{errors.ioText(e)}) catch "write failed" };
        return r.emit(&s.log);
    };
    if (silence(arena, outcomes, outputs)) |why| return @intCast(log.combineExit(x.d.exit, noOutput(s, why)));
    return @intCast(x.d.exit);
}

/// `nix build`'s names (`createOutLinks`): `PREFIX`, `PREFIX-1`, ... per
/// root, and `-OUTPUT` after it for an output other than `out`.
fn outLinks(arena: Allocator, io: Io, prefix: []const u8, outcomes: []const Outcome) ![]const backend.Link {
    const cwd = std.process.currentPathAlloc(io, arena) catch "/";
    var links: std.ArrayList(backend.Link) = .empty;
    for (outcomes, 0..) |o, i| for (o.outputs) |op| {
        var link: std.ArrayList(u8) = .empty;
        try link.appendSlice(arena, prefix);
        if (i > 0) try link.print(arena, "-{d}", .{i});
        if (!std.mem.eql(u8, op.name, "out")) try link.print(arena, "-{s}", .{op.name});
        try links.append(arena, .{ .path = op.path, .link = try api.absPath(arena, cwd, link.items) });
    };
    return links.items;
}

/// A run that printed no store path for a target it was asked to build.
/// `iets build` is read by capturing its stdout, so the caller gets a path
/// or a non-zero exit, never silence and success
/// (docs/reference/errors.md).
fn noOutput(s: *Session, why: []const u8) u8 {
    const r: log.Report = .{ .code = "no-output", .raw = why };
    return r.emit(&s.log);
}

/// The stdout contract, checked: why a target put no store path on stdout,
/// or null when every target did. A build that failed reported itself
/// already and its exit code carries it, so it is not named again here.
fn silence(arena: Allocator, outcomes: []const Outcome, wanted: []const []const u8) ?[]const u8 {
    if (outcomes.len == 0) return "the builder returned no build result";
    for (outcomes) |o| {
        if (o.outputs.len > 0) continue;
        if (o.skipped) return std.fmt.allocPrint(arena, "'{s}' was not built: {s}", .{ o.attr, o.reason orelse "the builder gave no reason" }) catch "not built";
        if (!o.success) continue;
        if (wanted.len == 0)
            return std.fmt.allocPrint(arena, "'{s}' built, but the builder has no output path for '{f}'", .{ o.attr, &o.drv }) catch "no output";
        var w: std.ArrayList(u8) = .empty;
        for (wanted, 0..) |x, i| {
            if (i > 0) w.appendSlice(arena, ", ") catch {};
            w.appendSlice(arena, x) catch {};
        }
        return std.fmt.allocPrint(arena, "'{s}' built, but the builder has no output {s} of '{f}'", .{ o.attr, w.items, &o.drv }) catch "no output";
    }
    return null;
}

/// `--dry-run`: the sets as log records, as shared.cc:printMissing writes
/// them, and with `--json` the contract shape beside them on stdout.
fn printMissing(s: *Session, arena: Allocator, m: worker.Missing, p: *const Plan, json: bool) u8 {
    const ms = api_render.Missing.of(arena, m, p) catch return 1;
    out.missing(s, arena, &ms) catch return 1;
    if (json) {
        var buf: Writer.Allocating = .init(arena);
        ms.json(&buf.writer) catch return 1;
        buf.writer.writeByte('\n') catch return 1;
        out.bytes(s, buf.written()) catch return 1;
    }
    return 0;
}

/// `--timings`: one line per phase of the flow, as the backend measured it.
fn timings(s: *Session, b: *const BuildArgs, x: *apibuild.Dispatch, plan_time: u64) void {
    if (!b.timings) return;
    var buf: Writer.Allocating = .init(s.gpa);
    defer buf.deinit();
    x.d.report(&buf.writer, &x.plan, plan_time) catch return;
    s.log.errln(buf.written());
}

const testing = std.testing;

test "installables are sorted without repeats" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a: EvalArgs = .{ .more = &.{ .{ .flake = ".#b" }, .{ .flake = ".#a" }, .{ .flake = ".#b" } }, .input = .{ .flake = ".#c" } };
    const all = try installables(arena.allocator(), &a);
    try testing.expectEqual(3, all.len);
    for ([_][]const u8{ ".#a\x00", ".#b\x00", ".#c\x00" }, all) |w, x| try testing.expectEqualStrings(w, try label(arena.allocator(), &x));
}

fn testOutcome(success: bool, skipped: bool, outputs: []const Output) Outcome {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    return .{
        .attr = "top",
        .drv = StorePath.parse("/nix/store/00000000000000000000000000000000-top.drv", &d) catch unreachable,
        .success = success,
        .skipped = skipped,
        .reason = if (skipped) "the builder returned no build result" else null,
        .outputs = outputs,
        .exit = if (success) 0 else 1,
    };
}

test "why a build printed nothing on stdout" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out1 = [_]Output{.{ .name = "out", .path = "/nix/store/aaa-top-out" }};
    try testing.expectEqual(null, silence(a, &.{testOutcome(true, false, &out1)}, &.{}));
    try testing.expectEqual(null, silence(a, &.{testOutcome(false, false, &.{})}, &.{}));
    try testing.expect(std.mem.indexOf(u8, silence(a, &.{testOutcome(true, false, &.{})}, &.{}).?, "no output path") != null);
    try testing.expect(std.mem.indexOf(u8, silence(a, &.{testOutcome(true, false, &.{})}, &.{"dev"}).?, "no output dev") != null);
    const why = silence(a, &.{testOutcome(false, true, &.{})}, &.{}).?;
    try testing.expect(std.mem.indexOf(u8, why, "was not built") != null);
    try testing.expect(std.mem.indexOf(u8, why, "no build result") != null);
    try testing.expect(std.mem.indexOf(u8, silence(a, &.{}, &.{}).?, "no build result") != null);
}

test "out-links are named as nix build names them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const o1 = [_]Output{.{ .name = "out", .path = "/nix/store/aaa-top-out" }};
    const o2 = [_]Output{ .{ .name = "dev", .path = "/nix/store/aaa-top-dev" }, .{ .name = "out", .path = "/nix/store/aaa-top-out" } };
    const links = try outLinks(arena.allocator(), testing.io, "/r/result", &.{ testOutcome(true, false, &o1), testOutcome(true, false, &o2) });
    try testing.expectEqual(3, links.len);
    for ([_][]const u8{ "/r/result", "/r/result-1-dev", "/r/result-1" }, links) |w, l| try testing.expectEqualStrings(w, l.link.?);
}
