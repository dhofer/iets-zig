//! `nix` (src/nix): the subcommands iets implements — `eval`, `build`,
//! `derivation show`, `print-dev-env`, `develop`, `search`, `fmt` and `flake
//! prefetch-inputs` — with the same exec fallback as the rest of classic
//! mode for everything else. See `docs/reference/classic.md`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Diag = @import("../../diag.zig").Diag;
const Evaluator = @import("../../eval/Evaluator.zig");
const import_ = @import("../../eval/import.zig");
const print = @import("../../eval/print.zig");
const value = @import("../../runtime/value.zig");
const Value = value.Value;
const config = @import("../../config.zig");
const remote = @import("../../remote.zig");
const worker = remote.worker;
const Transport = worker.Transport;
const plan_mod = remote.plan;
const path_mod = @import("../../store/path.zig");
const StorePath = path_mod.StorePath;
const api = @import("../../api.zig");
const apibuild = api.build;
const installable = api.installable;
const Root = installable.Root;
const Provenance = @import("../../provenance.zig").Provenance;
const backend = @import("../../build/backend.zig");
const cli = @import("../../cli.zig");
const devenv = @import("../devenv.zig");
const args_mod = @import("../args.zig");
const classic = @import("mod.zig");
const Cmd = classic.Cmd;
const Stop = classic.Stop;
const Common = classic.Common;
const Argv = classic.Argv;

const name = "nix";
const toml_timestamps = "parse-toml-timestamps";

/// The flags accepted before the subcommand, and how many values each
/// takes. `globalFlag` applies them; `findSub` only needs the arity.
const globals = [_]struct { []const u8, usize }{
    .{ "--impure", 0 },
    .{ "--pure-eval", 0 },
    .{ "--no-pure-eval", 0 },
    .{ "--accept-flake-config", 0 },
    .{ "--show-trace", 0 },
    .{ "--log-format", 1 },
    .{ "--experimental-features", 1 },
    .{ "--extra-experimental-features", 1 },
    .{ "--option", 2 },
    .{ "-I", 1 },
    .{ "--include", 1 },
    .{ "--arg", 2 },
    .{ "--argstr", 2 },
    .{ "--store", 1 },
    .{ "--flake-registry", 1 },
    // The `nix-farm` wrapper passes `--eval-store auto` because the farm
    // refuses the worker-protocol tunnel; iets always evaluates locally.
    .{ "--eval-store", 1 },
    .{ "-j", 1 },
    .{ "--max-jobs", 1 },
    .{ "--cores", 1 },
    .{ "-k", 0 },
    .{ "--keep-going", 0 },
};

fn global(s: []const u8) ?usize {
    for (globals) |g| if (std.mem.eql(u8, g[0], s)) return g[1];
    return null;
}

pub const Nix = struct {
    c: Common = .{},
    json: bool = false,
    raw: bool = false,
    expr: ?[]const u8 = null,
    file: ?[]const u8 = null,
    installables: std.ArrayList([]const u8) = .empty,
    /// The `-o`/`--out-link` prefix; `--no-link` clears it.
    out_link: []const u8 = "",
    no_link: bool = false,
    print_out_paths: bool = false,
    print_build_logs: bool = false,
    /// `derivation show -r`.
    recursive: bool = false,
    /// `--pretty`/`--no-pretty`; null leaves the terminal default.
    pretty: ?bool = null,

    /// The command line of a subcommand that takes installables. `own` gets
    /// each argument first and says whether it was one of its flags.
    pub fn parse(n: *Nix, k: *Cmd, argv: []const []const u8, comptime own: fn (*Nix, *Argv, []const u8) Stop!bool) Stop!void {
        const eql = std.mem.eql;
        var a: Argv = .{ .k = k, .all = argv };
        while (a.i < argv.len) : (a.i += 1) {
            const s = argv[a.i];
            if (try own(n, &a, s)) continue;
            if (eql(u8, s, "--expr")) {
                n.expr = try a.value(s);
            } else if (eql(u8, s, "-f") or eql(u8, s, "--file")) {
                n.file = try a.value(s);
            } else if (try globalFlag(&n.c, &a, s)) {
                // taken
            } else if (s.len > 0 and s[0] == '-') {
                return k.fallBack("'{s}' is not implemented", .{s});
            } else try n.installables.append(k.arena, s);
        }
        if (n.expr != null and n.file != null) return k.fallBack("'--file' and '--expr' are exclusive", .{});
    }

    /// installable-flake.cc: a flake installable refuses `--arg`/`--argstr`,
    /// so the real nix reports that better than iets would.
    pub fn checkArgsWithFlake(n: *const Nix, k: *Cmd) Stop!void {
        if (n.c.flags.args.items.len > 0 and n.expr == null and n.file == null)
            return k.fallBack("'--arg' and '--argstr' are incompatible with flakes", .{});
    }
};

/// Runs `nix <subcommand>`. `argv` is everything after `argv[0]`.
pub fn main(c: *const cli.Ctx, argv: []const []const u8) u8 {
    var k: Cmd = .init(c, name, argv);
    return k.finish(body(&k));
}

fn body(k: *Cmd) Stop!u8 {
    const eql = std.mem.eql;
    const argv = k.argv;
    const at = try findSub(k, argv);
    var rest: std.ArrayList([]const u8) = .empty;
    try rest.appendSlice(k.arena, argv[0..at]);
    try rest.appendSlice(k.arena, argv[at + 1 ..]);
    const sub = argv[at];
    if (eql(u8, sub, "eval")) return evalMain(k, rest.items);
    if (eql(u8, sub, "build")) return buildMain(k, rest.items);
    if (eql(u8, sub, "print-dev-env")) return devEnvMain(k, rest.items);
    if (eql(u8, sub, "develop")) return classic.develop.main(k, rest.items);
    if (eql(u8, sub, "fmt")) return classic.fmt.main(k, rest.items);
    if (eql(u8, sub, "search")) return searchMain(k, rest.items);
    if (eql(u8, sub, "derivation") and at < rest.items.len and eql(u8, rest.items[at], "show")) {
        _ = rest.orderedRemove(at);
        return classic.drvshow.main(k, rest.items);
    }
    if (eql(u8, sub, "flake") and at < rest.items.len and eql(u8, rest.items[at], "prefetch-inputs")) {
        _ = rest.orderedRemove(at);
        return prefetchInputsMain(k, rest.items);
    }
    return k.fallBack("subcommand '{s}'", .{sub});
}

/// The index of the subcommand word: the first argument that is not one of
/// the global flags iets accepts.
pub fn findSub(k: *Cmd, argv: []const []const u8) Stop!usize {
    var i: usize = 0;
    while (i < argv.len) {
        const s = argv[i];
        if (s.len == 0 or s[0] != '-') return i;
        const arity = global(s) orelse return k.fallBack("'{s}' is not implemented", .{s});
        i += 1 + arity;
    }
    return k.fallBack("no subcommand", .{});
}

/// True: consumed. False: not one of ours. `error.Fallback`: fall back.
pub fn globalFlag(cm: *Common, a: *Argv, s: []const u8) Stop!bool {
    const eql = std.mem.eql;
    const k = a.k;
    if (global(s) == null) return false;
    if (eql(u8, s, "--accept-flake-config")) {
        try k.s.ignored.flagForNixConfig(s);
    } else if (eql(u8, s, "--experimental-features") or eql(u8, s, "--extra-experimental-features")) {
        // iets has every feature but this one, which changes what `fromTOML`
        // returns (docs/reference/divergences.md). In classic mode the
        // value is still a setting, because the builtins Nix gates on a
        // feature are gated here too (`builtins.install`).
        const v = try a.value(s);
        var it = std.mem.tokenizeAny(u8, v, " \t\n\r");
        while (it.next()) |f| if (eql(u8, f, toml_timestamps))
            return k.fallBack("'{s} {s}' is not implemented", .{ s, toml_timestamps });
        try cm.flags.overrides.append(k.arena, .{ .name = s[2..], .value = v });
    } else if (eql(u8, s, "--eval-store")) {
        const v = try a.value(s);
        if (v.len == 0 or eql(u8, v, "auto") or eql(u8, v, "daemon")) {
            try k.s.ignored.flag(s, "iets evaluates in memory and needs no evaluation store");
        } else return k.fallBack("'--eval-store {s}' is not implemented", .{v});
    } else return classic.commonFlag(cm, a, s);
    return true;
}

fn parseEval(k: *Cmd, argv: []const []const u8) Stop!Nix {
    var n: Nix = .{};
    try n.parse(k, argv, struct {
        fn own(x: *Nix, _: *Argv, s: []const u8) Stop!bool {
            const eql = std.mem.eql;
            if (eql(u8, s, "--json")) {
                x.json = true;
            } else if (eql(u8, s, "--raw")) {
                x.raw = true;
            } else if (eql(u8, s, "-L") or eql(u8, s, "--print-build-logs")) {
                // an evaluation that would build falls back, so there is no log
            } else return false;
            return true;
        }
    }.own);
    if (n.raw and n.json) return k.fallBack("--raw and --json are mutually exclusive", .{});
    if (n.installables.items.len > 1) return k.fallBack("'nix eval' takes one installable", .{});
    try n.checkArgsWithFlake(k);
    return n;
}

fn parseBuild(k: *Cmd, argv: []const []const u8) Stop!Nix {
    var n: Nix = .{ .out_link = "result" };
    try n.parse(k, argv, struct {
        fn own(x: *Nix, a: *Argv, s: []const u8) Stop!bool {
            const eql = std.mem.eql;
            if (eql(u8, s, "-o") or eql(u8, s, "--out-link")) {
                x.out_link = try a.value(s);
            } else if (eql(u8, s, "--no-link")) {
                x.no_link = true;
            } else if (eql(u8, s, "--print-out-paths")) {
                x.print_out_paths = true;
            } else if (eql(u8, s, "-L") or eql(u8, s, "--print-build-logs")) {
                x.print_build_logs = true;
            } else return false;
            return true;
        }
    }.own);
    if (n.installables.items.len == 0) try n.installables.append(k.arena, ".");
    try n.checkArgsWithFlake(k);
    return n;
}

/// `settings` (without `builder` unless `builder`) plus the `nix` command's
/// `pure-eval`. main.cc: pure unless a flag says otherwise; nix.conf's
/// setting does not change that, it only counts as set. installables.cc:
/// `--file` is impure, and refuses a `pure-eval` set anywhere.
pub fn nixSettings(k: *Cmd, cm: *Common, file: bool, builder: bool) Stop!classic.Settings {
    const st = try classic.settings(k, cm, builder);
    const set = cm.flags.pure != null or st.cfg.overridden("pure-eval");
    const pure = cm.flags.pure orelse true;
    if (file and pure and set) return k.fallBack("'--file' is not compatible with '--pure-eval'", .{});
    cm.flags.pure = pure and !file;
    return st;
}

/// The run of a `nix` subcommand: `classic.run` with no file entry (the
/// working directory starts the project walk) unless `--file` names one.
pub fn nixRun(k: *Cmd, n: *const Nix, cfg: *const config.Config) Stop!api.run.Run {
    const ea = try k.arena.create(api.EvalArgs);
    ea.* = try classic.evalArgs(k, &n.c, cfg);
    if (n.file) |f| ea.input = .{ .file = f };
    return classic.run(k, &n.c, cfg, ea);
}

/// The run's tracing cache of `subcommand`. The key is
/// what changes the answer: the installables, `--expr` or `--file`, the
/// `--arg`s, the search path, `pure-eval`, `--json` and `--raw`. `strict`
/// and `json` are the key fields a command without them is free to use. No
/// other flag the parsers accept reaches the evaluator.
pub fn nixCache(k: *Cmd, n: *const Nix, r: *api.run.Run, subcommand: []const u8, strict: bool, json: bool) void {
    var key = r.args.*;
    const all = n.installables.items;
    const first = if (all.len > 0) all[0] else ".";
    const more = if (all.len > 1) all[1..] else &.{};
    key.input = if (n.expr) |e| .{ .expr = e } else if (n.file) |f| .{ .file = f } else .{ .flake = first };
    key.attr = if (n.expr != null or n.file != null) first else null;
    key.attrs = &.{};
    key.strict = strict;
    key.json = json;
    key.raw = n.raw;
    classic.openCache(k, r, &key, subcommand, more);
}

/// Prints the stdout `Job.go` makes, from the tracing cache when `r` hits
/// it. `Job` has `k`, `cache` and `text`.
pub fn printCached(k: *Cmd, r: *const api.run.Run, job: anytype) Stop!u8 {
    defer if (r.cache) |c| c.deinit();
    if (r.cache != null) {
        const store = try classic.inputStore(k, r.args.cache_dir);
        defer store.deinit();
        if (classic.hitResult(k, r, store)) |text| {
            try classic.out(k, text);
            return 0;
        }
    }
    job.cache = r.cache;
    const code = try classic.ran(k, r.go(job, @TypeOf(job.*).go));
    if (code == 0) try classic.out(k, job.text);
    return code;
}

fn evalMain(k: *Cmd, rest: []const []const u8) Stop!u8 {
    var n = try parseEval(k, rest);
    const st = try nixSettings(k, &n.c, n.file != null, true);
    var r = try nixRun(k, &n, st.cfg);
    nixCache(k, &n, &r, "nix eval", false, n.json);
    var job: EvalJob = .{ .k = k, .n = &n };
    return printCached(k, &r, &job);
}

/// `nix eval`: the whole stdout, formatted before any of it is written.
const EvalJob = struct {
    k: *Cmd,
    n: *const Nix,
    cache: ?*api.cache.Cache = null,
    text: []const u8 = "",

    pub fn go(j: *EvalJob, ev: *Evaluator) !u8 {
        const n = j.n;
        const arena = j.k.arena;
        var out: Writer.Allocating = .init(arena);
        const w = &out.writer;
        const what = if (n.installables.items.len > 0) n.installables.items[0] else ".";
        var v = try resolve(ev, j.k, n, what);
        // installables.cc: the installable's value is forced before
        // printing, so an error at the top level is reported instead of printed.
        v = try ev.force(v);
        if (n.raw) {
            var text: std.ArrayList(u8) = .empty;
            defer text.deinit(ev.gpa);
            var ctx: std.ArrayList(value.Ctx) = .empty;
            defer ctx.deinit(ev.gpa);
            try ev.coerceToString(v, &text, &ctx, .none, "while generating the eval command output", .{});
            try w.writeAll(text.items);
        } else if (n.json) {
            var ctx: std.ArrayList(value.Ctx) = .empty;
            defer ctx.deinit(ev.gpa);
            print.writeJson(ev, w, v, &ctx, true, .none) catch |e| return print.inMemory(e);
            try w.writeByte('\n');
        } else {
            var seen: Seen = .empty;
            defer seen.deinit(ev.gpa);
            printEval(ev, v, w, &seen, 0) catch |e| return print.inMemory(e);
            try w.writeByte('\n');
        }
        j.text = out.written();
        if (j.cache) |c| try api.cache.writeEntry(c, j.k.s, ev, j.text, false);
        return 0;
    }
};

fn buildMain(k: *Cmd, rest: []const []const u8) Stop!u8 {
    var n = try parseBuild(k, rest);
    const st = try nixSettings(k, &n.c, n.file != null, true);
    var r = try nixRun(k, &n, st.cfg);
    nixCache(k, &n, &r, "nix build", false, false);
    defer if (r.cache) |c| c.deinit();
    var job: BuildJob = .{ .k = k, .n = &n, .transport = &st.transport, .options = st.options, .cache = r.cache };
    // a hit skips the evaluation and nothing else: the upload, the build,
    // the out-links and the roots all happen in `realise`
    if (r.cache != null) {
        const store = try classic.inputStore(k, r.args.cache_dir);
        defer store.deinit();
        if (classic.hitPlan(k, &r, store)) |h| {
            const code = job.realise(try remembered(k.arena, h.roots), h.tables.inputs()) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => 1,
            };
            if (code == 0) try classic.out(k, job.text);
            return code;
        }
    }
    const code = try classic.ran(k, r.go(&job, BuildJob.go));
    if (code == 0) try classic.out(k, job.text);
    return code;
}

/// The targets as a cache entry's roots, one per installable. The outputs
/// are joined with a comma, which no output name can hold (store path names
/// are `[A-Za-z0-9+._?=-]`), so the installables stay apart: the n-th one
/// names its own out-link.
fn remember(a: Allocator, targets: []const installable.Install) ![]const installable.DrvRoot {
    const out = try a.alloc(installable.DrvRoot, targets.len);
    for (targets, out) |t, *o| o.* = .{ .drv = t.drv, .output = try std.mem.join(a, ",", t.outputs) };
    return out;
}

fn remembered(a: Allocator, roots: []const @import("../../trace.zig").wire.Root) ![]const installable.Install {
    const out = try a.alloc(installable.Install, roots.len);
    for (roots, out) |r, *o| {
        var outs: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, r.output orelse "", ',');
        while (it.next()) |x| try outs.append(a, x);
        o.* = .{ .drv = r.drv, .outputs = outs.items };
    }
    return out;
}

const BuildJob = struct {
    k: *Cmd,
    n: *const Nix,
    transport: *const Transport,
    options: worker.Options,
    cache: ?*api.cache.Cache = null,
    text: []const u8 = "",

    /// `nix build`: what to build, the closure to upload, and the build.
    fn go(j: *BuildJob, ev: *Evaluator) !u8 {
        const k = j.k;
        const n = j.n;
        const arena = k.arena;
        var targets: std.ArrayList(installable.Install) = .empty;
        for (n.installables.items) |what| {
            const v = try resolve(ev, k, n, what);
            try targets.append(arena, try installable.toInstall(ev, arena, v, what, n.expr == null and n.file == null));
        }
        if (j.cache) |c| try api.cache.writeBuild(c, k.s, ev, try remember(arena, targets.items));
        var inputs: apibuild.EvalInputs = .init(ev);
        defer inputs.deinit();
        return j.realise(targets.items, inputs.inputs());
    }

    /// Uploads the closure, builds every target in one call, makes the
    /// symlinks (command.cc:createOutLinks) and prints with
    /// `--print-out-paths`.
    fn realise(j: *BuildJob, targets: []const installable.Install, inputs: plan_mod.Inputs) !u8 {
        const k = j.k;
        const s = k.s;
        const n = j.n;
        const arena = k.arena;
        var d: Diag = .init(s.gpa);
        defer d.deinit();
        const roots = try flatRoots(arena, targets);
        const paths_in = try arena.alloc(StorePath, roots.len);
        for (roots, paths_in) |r, *p| p.* = r.drv;
        const p = plan_mod.plan(s.gpa, s.io, paths_in, inputs, &d) catch |e| return classic.report(s, &d, e);
        var prov: Provenance = .off(s.gpa);
        defer prov.deinit();
        var style: apibuild.Style = .detect(&s.log);
        style.quiet = !n.print_build_logs;
        var x = apibuild.Dispatch.open(s, k.c.init.environ_map, j.transport, j.options, p, &prov, style, &d) catch |e| return classic.report(s, &d, e);
        defer x.deinit();
        const built = x.realise(arena, roots, {}, struct {
            fn f(_: void, sp: *const StorePath) []const u8 {
                return sp.name();
            }
        }.f, &d) catch |e| return classic.report(s, &d, e);
        // a daemon client nix exits 1 on a failed build, whatever the status
        if (x.d.exit != 0) return 1;
        const paths = built.paths(arena, roots, &d) catch |e| return classic.report(s, &d, e);

        var out: std.ArrayList(u8) = .empty;
        var links: std.ArrayList(backend.Link) = .empty;
        var kept: std.ArrayList([2][]const u8) = .empty;
        var at: usize = 0;
        for (targets, 0..) |t, i| for (t.outputs) |output| {
            const path = paths[at];
            at += 1;
            if (n.no_link) {
                if (!classic.storeGiven(&n.c)) {
                    try links.append(arena, .{ .path = path, .link = null });
                    try kept.append(arena, .{ try std.fmt.allocPrint(arena, "{d}!{s}", .{ i, output }), path });
                }
            } else {
                // build.cc: the n-th installable adds `-n` from 1 on, an
                // output other than `out` adds `-<output>`.
                var link: std.ArrayList(u8) = .empty;
                try link.appendSlice(arena, n.out_link);
                if (i > 0) try link.print(arena, "-{d}", .{i});
                if (!std.mem.eql(u8, output, "out")) try link.print(arena, "-{s}", .{output});
                try links.append(arena, .{ .path = path, .link = try classic.absPath(k, link.items) });
            }
            if (n.print_out_paths) try out.print(arena, "{s}\n", .{path});
        };
        x.d.outLinks(links.items, &d) catch |e| return classic.report(s, &d, e);
        // `--no-link` keeps a root instead of nothing, as `nix-build
        // --no-out-link` does (build.zig, docs/reference/divergences.md)
        var key: std.ArrayList([]const u8) = .empty;
        try key.append(arena, "nix build");
        try key.append(arena, try classic.cwd(k));
        try key.appendSlice(arena, n.installables.items);
        if (n.file) |f| try key.append(arena, f);
        if (n.expr) |e| try key.append(arena, e);
        const t = try classic.local(k);
        const dc: devenv.Ctx = .{ .s = s, .env_map = k.c.init.environ_map, .log = .of(&s.log) };
        devenv.keepOutputs(&dc, &t, key.items, kept.items);
        j.text = out.items;
        return 0;
    }
};

/// The `Root`s the plan and `BuildPathsWithResults` need, in target order.
fn flatRoots(a: Allocator, targets: []const installable.Install) ![]const Root {
    var roots: std.ArrayList(Root) = .empty;
    for (targets) |t| for (t.outputs) |o| try roots.append(a, .{ .drv = t.drv, .output = o });
    return roots.items;
}

/// `nix search`.
fn searchMain(k: *Cmd, rest: []const []const u8) Stop!u8 {
    return cli.search.classicMain(k, rest);
}

/// flake-prefetch-inputs.cc: every locked input the lock reaches, resolved
/// in parallel the way an evaluation resolves it (`cli/prefetch.zig`). A
/// lock that is missing or incomplete needs locking, which the real nix
/// does.
fn prefetchInputsMain(k: *Cmd, rest: []const []const u8) Stop!u8 {
    var cm: Common = .{};
    var refs: std.ArrayList([]const u8) = .empty;
    var a: Argv = .{ .k = k, .all = rest };
    while (a.i < rest.len) : (a.i += 1) {
        const s = rest[a.i];
        if (try globalFlag(&cm, &a, s)) continue;
        if (s.len > 0 and s[0] == '-') return k.fallBack("'{s}' is not implemented", .{s});
        try refs.append(k.arena, s);
    }
    if (refs.items.len > 1) return k.fallBack("'nix flake prefetch-inputs' takes one flake", .{});
    const cwd = try classic.cwd(k);
    var d: Diag = .init(k.arena);
    const fr = api.flake.flakeRef(k.arena, k.s.io, if (refs.items.len > 0) refs.items[0] else ".", cwd, &d) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return k.fallBack("{s}", .{d.message()}),
    };
    const info = api.flake.info(k.arena, k.s.io, &fr, &d) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return k.fallBack("{s}", .{d.message()}),
    };
    const todo = info.inputs(k.arena, &d) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return k.fallBack("{s}", .{d.message()}),
    };
    return k.exit(try @import("../prefetch.zig").fetchInputs(k.s, k.arena, todo));
}

fn devEnvMain(k: *Cmd, rest: []const []const u8) Stop!u8 {
    var req: devenv.Request = .{};
    var json = false;
    var flakes: usize = 0;
    for (rest) |s| {
        const flag = s.len > 0 and s[0] == '-';
        if (flag and !std.mem.eql(u8, s, "--json")) return k.fallBack("'{s}' is not implemented", .{s});
        if (flag) json = true else {
            flakes += 1;
            req.flake = s;
        }
    }
    if (flakes > 1) return k.fallBack("'nix print-dev-env' takes one installable", .{});
    // `iets print-dev-env`'s errors and exit codes from here on
    k.s.log.command = "print-dev-env";
    // print-dev-env takes only a flake: `parse_eval_args(&[])`
    var a: args_mod.Args = .{ .s = k.s, .arena = k.arena, .cmd = "print-dev-env", .argv = &.{} };
    req.eval = (args_mod.parseEvalArgs(&a, &.{}) catch |e| return a.report(e)).eval;
    req.eval.json = json;
    // no flag reached here, so main.cc's default stands
    req.eval.pure = true;
    return devenv.run(k.c, &req);
}

/// The value one installable names: an attribute of the `--expr`/`--file`
/// value, or a flake output attribute.
pub fn resolve(ev: *Evaluator, k: *Cmd, n: *const Nix, what: []const u8) Evaluator.Error!Value {
    const arena = k.arena;
    const dir = classic.cwd(k) catch return error.OutOfMemory;
    const args = try api.autoArgs(ev, arena, n.c.flags.args.items);
    // installable-attr-path.cc:parse: `.` is the whole value.
    const attr = if (std.mem.eql(u8, what, ".")) "" else what;
    if (n.expr) |e| {
        const root = try import_.evalString(ev, e);
        return installable.findAlongAttrPath(ev, root, attr, args);
    }
    if (n.file) |f| {
        const p = try classic.lookupFileArg(ev, arena, f, dir);
        const root = try import_.evalFile(ev, p, .none);
        return installable.findAlongAttrPath(ev, root, attr, args);
    }
    if (std.mem.indexOfScalar(u8, what, '^') != null or std.mem.startsWith(u8, what, path_mod.store_dir))
        return classic.unsupported(ev, "the installable '{s}' is a store path", .{what});
    const hash_at = std.mem.indexOfScalar(u8, what, '#');
    const loc = what[0 .. hash_at orelse what.len];
    const fragment = if (hash_at) |i| what[i + 1 ..] else "";
    var d: Diag = .init(arena);
    const fr = api.flake.flakeRef(arena, ev.io, loc, dir, &d) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return classic.unsupported(ev, "{s}", .{d.message()}),
    };
    const outputs = try api.flake.outputs(ev, &fr);
    const found = try installable.fromOutputs(ev, arena, outputs, loc, .package, fragment, false);
    return found[0].value;
}

const Seen = std.AutoHashMapUnmanaged(u64, void);

/// An error the printer shows in place of the value. `unsupported` must
/// escape so the caller can fall back to the real nix instead.
fn printable(ev: *const Evaluator) bool {
    const f = ev.failure orelse return false;
    return f.kind != .unsupported and f.kind != .stack_overflow;
}

/// `nix eval`'s printer (print.cc:Printer with `force`, `derivationPaths`
/// and `trackRepeated`): forces as it goes, prints a derivation as its drv
/// path and a failing value as `«error: …»`.
fn printEval(ev: *Evaluator, v_in: Value, w: *Writer, seen: *Seen, depth: usize) (Evaluator.Error || Writer.Error)!void {
    if (depth > Evaluator.max_call_depth) return ev.fail(.stack_overflow, .none, "stack overflow; max-call-depth exceeded", .{});
    const v = ev.force(v_in) catch |e| {
        if (e != error.EvalFailed or !printable(ev)) return e;
        // docs/explanation/caching.md: errors are never cached. A read that
        // failed leaves no observation of the absence, so an entry holding
        // this text would replay it after the path appeared.
        ev.trace().markUncacheable();
        try w.print("«error: {s}»", .{ev.failure.?.msg});
        ev.clearFailure();
        return;
    };
    switch (v.view()) {
        .attrs => |a| {
            // Nix keys the seen set on the `Bindings` and shares one empty
            // `Bindings`, so the second empty attrset is «repeated».
            const key: u64 = if (a.len == 0) 0 else v.bits();
            if ((try seen.getOrPut(ev.gpa, key)).found_existing) return w.writeAll("«repeated»");
            if (try derivationPath(ev, v)) |drv| {
                try w.writeAll("«derivation");
                if (drv.len > 0) try w.print(" {s}", .{drv});
                return w.writeAll("»");
            }
            try w.writeAll("{ ");
            const sorted = try print.lexicographic(ev, a);
            defer ev.gpa.free(sorted);
            for (sorted) |at| {
                try print.writeAttrName(w, ev.interner.name(at.sym));
                try w.writeAll(" = ");
                try printEval(ev, at.cell.get(), w, seen, depth + 1);
                try w.writeAll("; ");
            }
            try w.writeByte('}');
        },
        .list => |l| {
            if (l.len > 0 and (try seen.getOrPut(ev.gpa, v.bits())).found_existing) return w.writeAll("«repeated»");
            try w.writeAll("[ ");
            for (l.cells()) |*c| {
                try printEval(ev, c.get(), w, seen, depth + 1);
                try w.writeByte(' ');
            }
            try w.writeByte(']');
        },
        .primop => |p| try w.print("«primop {s}»", .{primopName(p.name())}),
        .primop_app => |p| try w.print("«partially applied primop {s}»", .{primopName(p.op.name())}),
        .lambda => try w.print("{f}", .{print.short(ev, v)}),
        else => try print.writeAmbiguous(ev, w, v),
    }
}

/// eval.cc:addPrimOp drops a leading `__` from a primop's name, so that is
/// the name print.cc:printFunction shows.
fn primopName(n: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, n, "__")) n[2..] else n;
}

/// print.cc:printDerivation: the drv path when the attrset is a derivation,
/// which the printer shows instead of the attributes; "" when it has none.
fn derivationPath(ev: *Evaluator, v: Value) Evaluator.Error!?[]const u8 {
    if (v.kind() != .attrs) return null;
    const attrs = v.as(value.Attrs);
    const t = attrs.get(ev.s.type) orelse return null;
    const ts = try ev.forceString(t.cell.get(), .none, "while evaluating the 'type' attribute");
    if (!std.mem.eql(u8, ts.bytes(), "derivation")) return null;
    const dp = attrs.get(ev.s.drvPath) orelse return "";
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(ev.gpa);
    var ctx: std.ArrayList(value.Ctx) = .empty;
    defer ctx.deinit(ev.gpa);
    try ev.coerceToString(dp.cell.get(), &text, &ctx, dp.pos, "while evaluating the drvPath of a derivation", .{ .copy_to_store = false });
    return try ev.local.arena.dupe(u8, text.items);
}

const testing = std.testing;

test "global flags take their arity" {
    try testing.expectEqual(@as(?usize, 1), global("--flake-registry"));
    try testing.expectEqual(@as(?usize, 2), global("--option"));
    try testing.expectEqual(@as(?usize, null), global("--nope"));
    try testing.expectEqualStrings("add", primopName("__add"));
    try testing.expectEqualStrings("map", primopName("map"));
}

/// A command with no process behind it, for the parsers.
fn testCmd(s: *@import("../../session.zig").Session, arena: Allocator) Cmd {
    return .{ .c = undefined, .s = s, .arena = arena, .name = name, .argv = &.{} };
}

fn testFlag(k: *Cmd, line: []const []const u8) Stop!bool {
    var cm: Common = .{};
    var a: Argv = .{ .k = k, .all = line };
    return globalFlag(&cm, &a, line[0]);
}

test "a flag with no effect is noted and one that holds is not" {
    const Session = @import("../../session.zig").Session;
    const s = try Session.create(testing.allocator, testing.io, .{});
    defer s.destroy();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var k = testCmd(s, arena.allocator());
    try testing.expect(try testFlag(&k, &.{"--accept-flake-config"}));
    try testing.expect(try testFlag(&k, &.{ "--eval-store", "auto" }));
    try testing.expectError(error.Fallback, testFlag(&k, &.{ "--eval-store", "ssh-ng://b" }));
    try testing.expect(try testFlag(&k, &.{ "--extra-experimental-features", "nix-command flakes" }));
    try testing.expectError(error.Fallback, testFlag(&k, &.{ "--experimental-features", "flakes parse-toml-timestamps" }));
    for ([_][]const u8{ "-v", "--verbose", "--no-gc-warning", "--indirect" }) |f| {
        var cm: Common = .{};
        var a: Argv = .{ .k = &k, .all = &.{f} };
        try testing.expect(try classic.commonFlag(&cm, &a, f));
    }
    for ([_][]const u8{ "--accept-flake-config", "--eval-store", "--verbose" }) |f| try testing.expect(s.ignored.noted("ignored-flag", f));
    for ([_][]const u8{ "-v", "--no-gc-warning", "--indirect", "--extra-experimental-features" }) |f| try testing.expect(!s.ignored.noted("ignored-flag", f));
}

test "eval takes print-build-logs" {
    const Session = @import("../../session.zig").Session;
    const s = try Session.create(testing.allocator, testing.io, .{});
    defer s.destroy();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var k = testCmd(s, arena.allocator());
    _ = try parseEval(&k, &.{ "-L", "--expr", "1" });
    _ = try parseEval(&k, &.{ "--print-build-logs", "--expr", "1" });
}

test "flake-registry is the setting" {
    const Session = @import("../../session.zig").Session;
    const s = try Session.create(testing.allocator, testing.io, .{});
    defer s.destroy();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var k = testCmd(s, arena.allocator());
    const n = try parseBuild(&k, &.{ "--flake-registry", "", ".#a" });
    try testing.expectEqualStrings("flake-registry", n.c.flags.overrides.items[0].name);
    try testing.expectEqualStrings("", n.c.flags.overrides.items[0].value);
    const e = try parseEval(&k, &.{ "--flake-registry", "/r.json", "--expr", "1" });
    try testing.expectEqualStrings("/r.json", e.c.flags.overrides.items[0].value);
    try testing.expectEqual(2, try findSub(&k, &.{ "--flake-registry", "", "eval", "--expr", "1" }));
}
