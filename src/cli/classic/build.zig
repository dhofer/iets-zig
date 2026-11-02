//! `nix-build` (nix-build.cc). Evaluates, uploads the closure, builds every
//! root in one `BuildPathsWithResults`, makes the `result` symlinks and
//! prints the output paths.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Diag = @import("../../diag.zig").Diag;
const Evaluator = @import("../../eval/Evaluator.zig");
const remote = @import("../../remote.zig");
const worker = remote.worker;
const Transport = worker.Transport;
const plan_mod = remote.plan;
const StorePath = @import("../../store/path.zig").StorePath;
const api = @import("../../api.zig");
const apibuild = api.build;
const installable = api.installable;
const Root = installable.Root;
const provenance = @import("../../provenance.zig");
const Provenance = provenance.Provenance;
const backend = @import("../../build/backend.zig");
const cli = @import("../../cli.zig");
const devenv = @import("../devenv.zig");
const classic = @import("mod.zig");
const Cmd = classic.Cmd;
const Stop = classic.Stop;
const Common = classic.Common;
const Argv = classic.Argv;

const name = "nix-build";

const Build = struct {
    c: Common = .{},
    out_link: []const u8 = "./result",
    no_out_link: bool = false,
};

fn parse(k: *Cmd, argv: []const []const u8) Stop!Build {
    const eql = std.mem.eql;
    var b: Build = .{};
    var a: Argv = .{ .k = k, .all = argv };
    const unported = [_][]const u8{ "--dry-run", "--drv-link", "--run-env", "--command", "--run", "--repair", "--check", "--pure", "--exclude", "--keep", "-p", "--packages" };
    while (a.i < argv.len) : (a.i += 1) {
        const s = argv[a.i];
        if (eql(u8, s, "-o") or eql(u8, s, "--out-link")) {
            b.out_link = try a.value("--out-link");
        } else if (eql(u8, s, "--no-out-link") or eql(u8, s, "--no-link")) {
            b.no_out_link = true;
        } else if (eql(u8, s, "--add-drv-link")) {
            // nix-build.cc: "obsolete", a no-op in Nix too
        } else if (eql(u8, s, "-Q") or eql(u8, s, "--no-build-output")) {
            b.c.quiet = true;
        } else if (eql(u8, s, "-")) {
            return k.fallBack("reading the expression from stdin is not implemented", .{});
        } else if (for (unported) |u| {
            if (eql(u8, s, u)) break true;
        } else false) {
            return k.fallBack("'{s}' is not implemented", .{s});
        } else if (!try classic.commonFlag(&b.c, &a, s)) {
            if (s.len > 0 and s[0] == '-') return k.fallBack("'{s}' is not implemented", .{s});
            try b.c.files.append(k.arena, s);
        }
    }
    if (b.c.files.items.len == 0 and !b.c.from_args) try b.c.files.append(k.arena, ".");
    if (b.c.flags.attrs.items.len == 0) try b.c.flags.attrs.append(k.arena, "");
    return b;
}

pub fn main(c: *const cli.Ctx, argv: []const []const u8) u8 {
    var k: Cmd = .init(c, name, argv);
    return k.finish(body(&k));
}

fn body(k: *Cmd) Stop!u8 {
    var b = try parse(k, k.argv);
    const st = try classic.settings(k, &b.c, true);
    var ea = try classic.evalArgs(k, &b.c, st.cfg);
    var r = try classic.run(k, &b.c, st.cfg, &ea);
    // `nix-build`'s tracing cache, keyed apart from `nix build`'s: the
    // input, every `-A` in order, the `--arg`s, the search path and
    // `pure-eval`. A run with more than one input is not cached.
    if (b.c.files.items.len == 1) {
        var key = ea;
        const input = b.c.files.items[0];
        key.input = if (b.c.from_args) .{ .expr = input } else .{ .file = input };
        key.attr = b.c.flags.attrs.items[0];
        key.attrs = &.{};
        classic.openCache(k, &r, &key, name, b.c.flags.attrs.items[1..]);
    }
    defer if (r.cache) |c| c.deinit();
    var job: Job = .{ .k = k, .b = &b, .transport = &st.transport, .options = st.options, .cache = r.cache };
    // a hit skips the evaluation and nothing else: the upload, the build,
    // the links and the printing all happen in `realise`, as on a miss
    if (r.cache != null) {
        const store = try classic.inputStore(k, ea.cache_dir);
        defer store.deinit();
        if (classic.hitPlan(k, &r, store)) |h| {
            const roots = try k.arena.alloc(Root, h.roots.len);
            for (h.roots, roots) |x, *o| o.* = .{ .drv = x.drv, .output = x.output orelse "out" };
            const map = try h.tables.sourceMap(k.s.gpa, k.arena, k.s.settings.source_map);
            var prov: Provenance = .fromMap(map, k.s.settings.provenance);
            defer prov.deinit();
            return k.exit(realise(&job, roots, h.tables.inputs(), &prov) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => 1,
            });
        }
    }
    return classic.ran(k, r.go(&job, Job.go));
}

const Job = struct {
    k: *Cmd,
    b: *const Build,
    transport: *const Transport,
    options: worker.Options,
    cache: ?*api.cache.Cache = null,

    fn go(j: *Job, ev: *Evaluator) !u8 {
        const k = j.k;
        const b = j.b;
        const arena = k.arena;
        const dir = try classic.cwd(k);
        var roots: std.ArrayList(Root) = .empty;
        const args = try api.autoArgs(ev, arena, b.c.flags.args.items);
        for (b.c.files.items) |file| {
            const root = try classic.evalInput(ev, arena, &b.c, file, dir);
            for (b.c.flags.attrs.items) |attr| {
                // nix-build.cc: one `getDerivations` per attribute path, so
                // two of them that name one derivation give two roots
                var seen: installable.Seen = .empty;
                defer seen.deinit(ev.gpa);
                const v = try installable.findAlongAttrPath(ev, root, attr, args);
                try installable.getDrvsAt(ev, arena, v, args, &roots, &seen, attr);
            }
        }
        if (roots.items.len == 0) return 0;
        if (j.cache) |c| {
            const remembered = try arena.alloc(installable.DrvRoot, roots.items.len);
            for (roots.items, remembered) |x, *o| o.* = .{ .drv = x.drv, .output = x.output };
            try api.cache.writeBuild(c, k.s, ev, remembered);
        }
        var prov = try apibuild.snapshot(k.s, arena, ev);
        defer prov.deinit();
        var inputs: apibuild.EvalInputs = .init(ev);
        defer inputs.deinit();
        return realise(j, roots.items, inputs.inputs(), &prov);
    }
};

/// Uploads the closure, builds every root in one call, links and prints.
fn realise(j: *Job, roots: []const Root, inputs: plan_mod.Inputs, prov: *const Provenance) !u8 {
    const k = j.k;
    const s = k.s;
    const b = j.b;
    const arena = k.arena;
    var d: Diag = .init(s.gpa);
    defer d.deinit();
    const paths_in = try arena.alloc(StorePath, roots.len);
    for (roots, paths_in) |r, *p| p.* = r.drv;
    const p = plan_mod.plan(s.gpa, s.io, paths_in, inputs, &d) catch |e| return classic.report(s, &d, e);
    var style: apibuild.Style = .detect(&s.log);
    style.quiet = b.c.quiet;
    var x = apibuild.Dispatch.open(s, k.c.init.environ_map, j.transport, j.options, p, prov, style, &d) catch |e| return classic.report(s, &d, e);
    defer x.deinit();
    // nix-build asks for every root in one op, one output per root. The
    // bare attribute names each one: the dispatcher adds the position, once.
    const Names = struct {
        prov: *const Provenance,
        a: Allocator,
        fn f(n: @This(), sp: *const StorePath) []const u8 {
            const full = std.fmt.allocPrint(n.a, "{f}", .{sp}) catch return sp.name();
            return n.prov.attrOf(full) orelse provenance.drvName(full);
        }
    };
    const built = x.realise(arena, roots, Names{ .prov = prov, .a = arena }, Names.f, &d) catch |e| return classic.report(s, &d, e);
    // a daemon client nix exits 1 on a failed build, whatever the status
    if (x.d.exit != 0) return 1;
    const paths = built.paths(arena, roots, &d) catch |e| return classic.report(s, &d, e);

    // nix-build.cc: the n-th distinct drv gets the suffix `-n` from 2
    // on; an output other than `out` adds `-<output>`.
    var counter: std.StringArrayHashMapUnmanaged(usize) = .empty;
    for (roots) |r| {
        const n = counter.count();
        const g = try counter.getOrPut(arena, r.drv.baseName());
        if (!g.found_existing) g.value_ptr.* = n;
    }
    var out: std.ArrayList(u8) = .empty;
    var links: std.ArrayList(backend.Link) = .empty;
    var kept: std.ArrayList([2][]const u8) = .empty;
    for (roots, paths) |r, path| {
        const c = counter.get(r.drv.baseName()).?;
        if (b.no_out_link) {
            if (!classic.storeGiven(&b.c)) {
                try links.append(arena, .{ .path = path, .link = null });
                try kept.append(arena, .{ try std.fmt.allocPrint(arena, "{d}!{s}", .{ c, r.output }), path });
            }
        } else {
            var link: std.ArrayList(u8) = .empty;
            try link.appendSlice(arena, b.out_link);
            if (c > 0) try link.print(arena, "-{d}", .{c + 1});
            if (!std.mem.eql(u8, r.output, "out")) try link.print(arena, "-{s}", .{r.output});
            try links.append(arena, .{ .path = path, .link = try classic.absPath(k, link.items) });
        }
        try out.print(arena, "{s}\n", .{path});
    }
    x.d.outLinks(links.items, &d) catch |e| return classic.report(s, &d, e);
    try keepOutputs(k, b, kept.items);
    classic.outLossy(s, out.items);
    return 0;
}

/// In nix `--no-out-link` leaves the output collectable the moment the run
/// ends. Here it keeps a root in iets's roots store, keyed on the working
/// directory, the files and attributes asked for, and the name the symlink
/// would have had, so a second build replaces its own roots. This diverges
/// from Nix (`docs/reference/divergences.md`); `build-gc-root = false` turns
/// it off. The links go on the local daemon, where `outLinks` brought the
/// outputs.
fn keepOutputs(k: *Cmd, b: *const Build, kept: []const [2][]const u8) !void {
    var key: std.ArrayList([]const u8) = .empty;
    try key.append(k.arena, "nix-build");
    try key.append(k.arena, try classic.cwd(k));
    try key.appendSlice(k.arena, b.c.files.items);
    try key.appendSlice(k.arena, b.c.flags.attrs.items);
    const t = try classic.local(k);
    const dc: devenv.Ctx = .{ .s = k.s, .env_map = k.c.init.environ_map, .log = .of(&k.s.log) };
    devenv.keepOutputs(&dc, &t, key.items, kept);
}
