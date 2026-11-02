//! `iets plumbing OP`: the machine-first commands. One operation each,
//! JSON on stdout, a stable contract (docs/reference/plumbing.md).

const std = @import("std");
const render = @import("render.zig");
const text_ = @import("../syntax/text.zig");
const Io = std.Io;
const Writer = Io.Writer;
const Allocator = std.mem.Allocator;
const Diag = @import("../diag.zig").Diag;
const Session = @import("../session.zig").Session;
const log = @import("../log.zig");
const Report = log.Report;
const errors = @import("../errors.zig");
const cli = @import("../cli.zig");
const args_mod = @import("args.zig");
const Args = args_mod.Args;
const help = @import("help.zig");
const api = @import("../api.zig");
const EvalArgs = api.EvalArgs;
const Run = api.run.Run;
const installable = api.installable;
const apibuild = api.build;
const Missing = api.render.Missing;
const Outcomes = api.render.Outcomes;
const Evaluator = @import("../eval/Evaluator.zig");
const StorePath = @import("../store/path.zig").StorePath;
const drv_mod = @import("../store/drv.zig");
const remote = @import("../remote.zig");
const worker = remote.worker;
const plan = remote.plan;
const Plan = plan.Plan;
const Target = @import("../build/dispatch.zig").Target;
const backend = @import("../build/backend.zig");
const Provenance = @import("../provenance.zig").Provenance;
const locate = @import("../store/locate.zig");
const jobs = @import("../jobs.zig");
const hash_mod = @import("../store/hash.zig");

/// The operations: the tag is the word.
const Op = enum { resolve, plan, missing, build, fetch };

const ops = help.words(Op);

/// `iets plumbing`, from the command line's dispatch.
pub fn cmd(c: *const cli.Ctx, argv: []const []const u8) u8 {
    const s = c.s;
    s.log.command = "plumbing";
    var a: Args = .{ .s = s, .arena = c.init.arena.allocator(), .cmd = "plumbing", .argv = argv };
    // a command that reads no flag's value before it takes `--help`
    // anywhere
    for (argv) |x| if (std.mem.eql(u8, x, "--help") or std.mem.eql(u8, x, "-h")) return a.report(error.Help);
    return op(c, &a, argv) catch |e| a.report(e);
}

fn op(c: *const cli.Ctx, a: *Args, argv: []const []const u8) args_mod.Error!u8 {
    if (argv.len == 0) return a.fail("missing subcommand: resolve or plan or missing or build or fetch", .{});
    const w = argv[0];
    const rest = argv[1..];
    const which = std.meta.stringToEnum(Op, w) orelse {
        a.maybe = try help.suggest(a.arena, w, &ops);
        return a.fail("unknown subcommand '{s}'", .{w});
    };
    return switch (which) {
        .resolve => resolve(c, a, rest),
        .plan => opPlan(c, a, rest),
        .missing => opMissing(c, a, rest),
        .build => opBuild(c, a, rest),
        .fetch => opFetch(c, a, rest),
    };
}

/// A failure outside the evaluator, reported; the exit code.
fn fail(s: *Session, d: *const Diag, e: anyerror) u8 {
    return errors.report(e, d).emit(&s.log);
}

// resolve

/// `--walk`: how a value becomes derivation roots.
const Walk = enum {
    /// The `drvPath` attribute, or the derivations in a string's context.
    context,
    /// get-drvs.cc:getDerivations, what `nix-build` and `nix-shell` do.
    get_drvs,
    /// get-drvs.cc:queryOutputs, what `nix build` installs.
    to_install,
};

const Opts = struct {
    /// Null is `--prefixes none`: the fragment names the path itself.
    prefixes: ?installable.Prefixes = .package,
    want_all: bool = false,
    walk: Walk = .context,
    drvs: bool = true,
};

fn resolve(c: *const cli.Ctx, a: *Args, argv: []const []const u8) args_mod.Error!u8 {
    const eql = std.mem.eql;
    var o: Opts = .{};
    var rest: std.ArrayList([]const u8) = .empty;
    a.argv = argv;
    a.i = 0;
    while (a.i < argv.len) : (a.i += 1) {
        const x = argv[a.i];
        if (eql(u8, x, "--prefixes")) {
            const v = try a.next(x);
            o.prefixes = if (eql(u8, v, "none")) null else installable.Prefixes.parse(v) orelse
                return a.fail("--prefixes wants none, package, dev-shell or package-set, got '{s}'", .{v});
        } else if (eql(u8, x, "--want")) {
            const v = try a.next(x);
            o.want_all = if (eql(u8, v, "first")) false else if (eql(u8, v, "all")) true else return a.fail("--want wants first or all, got '{s}'", .{v});
        } else if (eql(u8, x, "--walk")) {
            const v = try a.next(x);
            o.walk = if (eql(u8, v, "context")) .context else if (eql(u8, v, "get-drvs")) .get_drvs else if (eql(u8, v, "to-install")) .to_install else return a.fail("--walk wants context, get-drvs or to-install, got '{s}'", .{v});
        } else if (eql(u8, x, "--no-drvs")) {
            o.drvs = false;
        } else try rest.append(a.arena, x);
    }
    const p = try args_mod.parseEvalArgs(a, rest.items);
    if (p.eval.input == null) return a.fail("nothing to resolve: give -E EXPR, FILE or FLAKEREF[#FRAGMENT]", .{});
    const ea = try a.arena.create(EvalArgs);
    ea.* = p.eval;
    const run: Run = .{ .s = c.s, .init = c.init, .args = ea };
    const job: ResolveJob = .{ .run = &run, .o = o };
    return run.go(&job, ResolveJob.go);
}

const ResolveJob = struct {
    run: *const Run,
    o: Opts,

    fn go(j: *const ResolveJob, ev: *Evaluator) !u8 {
        const s = j.run.s;
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const ea = j.run.args;
        const o = j.o;
        const what: []const u8 = if (ea.input) |i| switch (i) {
            .flake, .file => |f| f,
            .expr => "",
        } else "";
        const is_flake = ea.input != null and ea.input.? == .flake;
        // a flake installable is tried at the attribute paths of `o.prefixes`
        var paths: []const []const u8 = &.{};
        var found: std.ArrayList(installable.Found) = .empty;
        if (is_flake and o.prefixes != null) {
            const f = ea.input.?.flake;
            const hash_at = std.mem.indexOfScalar(u8, f, '#');
            const loc = f[0 .. hash_at orelse f.len];
            const frag = if (hash_at) |i| f[i + 1 ..] else "";
            paths = try installable.attrPaths(arena, o.prefixes.?, frag, ev.config.system);
            var whole = ea.*;
            whole.input = .{ .flake = loc };
            whole.attr = null;
            const outputs = try api.evaluate(ev, arena, &whole, try j.run.cwd());
            try found.appendSlice(arena, try installable.fromOutputs(ev, arena, outputs, loc, o.prefixes.?, frag, o.want_all));
        } else try found.append(arena, .{ .value = try api.evaluate(ev, arena, ea, try j.run.cwd()), .path = ea.attr orelse "" });
        const from_flake = is_flake and o.prefixes != null;

        var out: Writer.Allocating = .init(s.gpa);
        defer out.deinit();
        const w = &out.writer;
        // the keys sorted, as Rust iets writes them: attrPaths, drvDir, roots
        try w.writeAll("{\"attrPaths\":[");
        for (paths, 0..) |p, i| {
            if (i > 0) try w.writeByte(',');
            try text_.writeJsonString(w, p);
        }
        try w.writeByte(']');
        if (ea.dump_drvs) |dir| {
            // an op downstream reads the closure from there instead of
            // /nix/store
            try w.writeAll(",\"drvDir\":");
            try text_.writeJsonString(w, dir);
        }
        try w.writeAll(",\"roots\":[");
        var first = true;
        for (found.items) |fv| {
            const v = fv.value;
            const attr: ?[]const u8 = if (from_flake) fv.path else ea.attr;
            if (o.drvs) switch (o.walk) {
                .context => {
                    var rs: std.ArrayList(installable.DrvRoot) = .empty;
                    try installable.drvRoots(ev, arena, v, &rs);
                    for (rs.items) |r| try rootJson(w, &first, &r.drv, r.output, attr);
                },
                .get_drvs => {
                    const auto = try api.autoArgs(ev, arena, ea.args);
                    var rs: std.ArrayList(installable.Root) = .empty;
                    var seen: installable.Seen = .empty;
                    defer seen.deinit(ev.gpa);
                    try installable.getDrvsAt(ev, arena, v, auto, &rs, &seen, attr orelse "");
                    for (rs.items) |r| {
                        // the walk records the path it reached each derivation by
                        const at = blk: {
                            ev.shared.drv_lock.lock(ev);
                            defer ev.shared.drv_lock.unlock(ev);
                            const info = ev.shared.drv.table.get(r.drv.baseName()) orelse break :blk attr;
                            break :blk info.attr orelse attr;
                        };
                        try rootJson(w, &first, &r.drv, r.output, at);
                    }
                },
                .to_install => {
                    const i = try installable.toInstall(ev, arena, v, what, is_flake);
                    for (i.outputs) |name| try rootJson(w, &first, &i.drv, name, attr);
                },
            };
        }
        try w.writeAll("]}\n");
        var d: Diag = .init(s.gpa);
        defer d.deinit();
        render.write(s, out.written(), &d) catch |e| return fail(s, &d, e);
        return 0;
    }
};

/// One entry of `resolve`'s `roots`. `output` is null when the value named
/// the derivation and not one output.
fn rootJson(w: *Writer, first: *bool, drv: *const StorePath, output: ?[]const u8, attr: ?[]const u8) Writer.Error!void {
    if (!first.*) try w.writeByte(',');
    first.* = false;
    try w.writeAll("{\"attr\":");
    if (attr) |x| try text_.writeJsonString(w, x) else try w.writeAll("null");
    try w.print(",\"drv\":\"{f}\",\"output\":", .{drv});
    if (output) |x| try text_.writeJsonString(w, x) else try w.writeAll("null");
    try w.writeByte('}');
}

// The roots of plan, missing and build

/// What an op works on: the roots, and the directory their derivations were
/// dumped to, if any.
const Roots = struct {
    targets: []Target,
    /// `resolve --dump-drvs DIR`: the closure is read from there, not from
    /// `/nix/store`.
    drv_dir: ?[]const u8,

    fn paths(r: *const Roots, a: Allocator) ![]StorePath {
        const out = try a.alloc(StorePath, r.targets.len);
        for (r.targets, out) |t, *p| p.* = t.drv;
        return out;
    }
};

/// What `splitFlags` leaves: the root words, `--roots -` and `--drvs DIR`.
const Split = struct {
    words: []const []const u8 = &.{},
    stdin: bool = false,
    drvs: ?[]const u8 = null,
};

/// `--roots -`, `--drvs DIR` plus the flags `flags.flag` accepts; what is
/// left are the root words.
fn splitFlags(a: *Args, argv: []const []const u8, flags: anytype) args_mod.Error!Split {
    const eql = std.mem.eql;
    var out: Split = .{};
    var rest: std.ArrayList([]const u8) = .empty;
    a.argv = argv;
    a.i = 0;
    while (a.i < argv.len) : (a.i += 1) {
        const x = argv[a.i];
        if (eql(u8, x, "--roots")) {
            if (!eql(u8, try a.next(x), "-")) return a.fail("--roots takes '-': the roots come from stdin", .{});
            out.stdin = true;
        } else if (eql(u8, x, "--drvs")) {
            out.drvs = try a.next(x);
        } else if (!try flags.flag(a, x)) {
            if (std.mem.startsWith(u8, x, "-")) return a.unknownFlag(x);
            try rest.append(a.arena, x);
        }
    }
    out.words = rest.items;
    return out;
}

/// Targets, one per derivation, their outputs merged.
const TargetSet = struct {
    a: *Args,
    items: std.ArrayList(Target) = .empty,
    outs: std.ArrayList(std.ArrayList([]const u8)) = .empty,

    fn add(t: *TargetSet, drv_s: []const u8, output: ?[]const u8) args_mod.Error!void {
        const a = t.a;
        var d: Diag = .init(a.arena);
        const drv = StorePath.parse(drv_s, &d) catch return a.fail("'{s}' is not a store path: {s}", .{ drv_s, d.message() });
        const i = for (t.items.items, 0..) |x, k| {
            if (x.drv.eql(&drv)) break k;
        } else blk: {
            try t.items.append(a.arena, .{ .attr = try a.arena.dupe(u8, drv.name()), .drv = drv });
            try t.outs.append(a.arena, .empty);
            break :blk t.items.items.len - 1;
        };
        const o = output orelse return;
        var it = std.mem.splitScalar(u8, o, ',');
        while (it.next()) |name| if (name.len > 0) try addName(a.arena, &t.outs.items[i], name);
    }

    fn finish(t: *TargetSet) []Target {
        for (t.items.items, t.outs.items) |*x, o| x.outputs = o.items;
        return t.items.items;
    }
};

fn addName(a: Allocator, list: *std.ArrayList([]const u8), name: []const u8) !void {
    for (list.items) |x| if (std.mem.eql(u8, x, name)) return;
    try list.append(a, name);
}

/// The roots an op works on, one target per derivation. An argument is
/// `DRV` or `DRV!OUT[,OUT]`; `--roots -` reads a previous op's stdout
/// instead, the `roots` of a `resolve` or the `drvs` of a `plan`, and its
/// `drvDir` when it has one. No output name means every output, as `!*`
/// does in the worker protocol.
fn roots(c: *const cli.Ctx, a: *Args, sp: Split) args_mod.Error!Roots {
    var drv_dir = sp.drvs;
    var set: TargetSet = .{ .a = a };
    if (sp.stdin) {
        var buf: [4096]u8 = undefined;
        var r = Io.File.stdin().readerStreaming(c.init.io, &buf);
        const text = r.interface.allocRemaining(a.arena, .unlimited) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return a.fail("--roots -: cannot read stdin: {s}", .{errors.ioText(r.err orelse e)}),
        };
        if (!std.unicode.utf8ValidateSlice(text)) return a.fail("--roots -: cannot read stdin: stream did not contain valid UTF-8", .{});
        if (try serdeError(a.arena, text)) |msg| return a.fail("--roots -: not JSON: {s}", .{msg});
        const v = std.json.parseFromSliceLeaky(std.json.Value, a.arena, text, .{ .duplicate_field_behavior = .use_last }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return a.fail("--roots -: not JSON: {s}", .{@errorName(e)}),
        };
        const bad = "--roots -: no \"roots\" and no \"drvs\" on stdin";
        const obj: ?std.json.ObjectMap = if (v == .object) v.object else null;
        if (obj) |m| if (m.get("drvDir")) |x| if (x == .string and drv_dir == null) {
            drv_dir = x.string;
        };
        const rs: ?std.json.Value = if (obj) |m| m.get("roots") else null;
        const ds: ?std.json.Value = if (obj) |m| m.get("drvs") else null;
        if (rs != null and rs.? == .array) {
            for (rs.?.array.items) |x| {
                const drv = if (x == .object) x.object.get("drv") else null;
                if (drv == null or drv.? != .string) return a.fail(bad, .{});
                const out = x.object.get("output");
                try set.add(drv.?.string, if (out != null and out.? == .string) out.?.string else null);
            }
        } else if (ds != null and ds.? == .array) {
            for (ds.?.array.items) |x| {
                if (x != .string) return a.fail(bad, .{});
                try set.add(x.string, null);
            }
        } else return a.fail(bad, .{});
    }
    for (sp.words) |w| {
        if (std.mem.indexOfScalar(u8, w, '!')) |i| try set.add(w[0..i], w[i + 1 ..]) else try set.add(w, null);
    }
    if (set.items.items.len == 0) return a.fail("nothing to do: give DRV... or --roots -", .{});
    return .{ .targets = set.finish(), .drv_dir = drv_dir };
}

/// The plan of the roots: from the derivations `--dump-drvs` wrote when
/// there are any, else from `/nix/store`. Sources come from the local store
/// either way; nothing here evaluated. The plan points into `table`.
fn planOf(s: *Session, a: Allocator, r: *const Roots, table: *apibuild.DrvTable, d: *Diag) !Plan {
    if (r.drv_dir) |dir| try table.addDir(s.io, dir, d);
    return plan.plan(s.gpa, s.io, try r.paths(a), table.inputs(), d);
}

const NoFlags = struct {
    fn flag(_: NoFlags, _: *Args, _: []const u8) args_mod.Error!bool {
        return false;
    }
};

fn opPlan(c: *const cli.Ctx, a: *Args, argv: []const []const u8) args_mod.Error!u8 {
    const r = try roots(c, a, try splitFlags(a, argv, NoFlags{}));
    const s = c.s;
    var d: Diag = .init(s.gpa);
    defer d.deinit();
    return planJson(s, a.arena, &r, &d) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => fail(s, &d, e),
    };
}

fn planJson(s: *Session, a: Allocator, r: *const Roots, d: *Diag) !u8 {
    var table: apibuild.DrvTable = .init(s.gpa);
    defer table.deinit();
    var p = try planOf(s, a, r, &table, d);
    defer p.deinit();
    var out: Writer.Allocating = .init(s.gpa);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"drvs\":[");
    for (p.drvs, 0..) |*o, i| try w.print("{s}\"{f}\"", .{ if (i > 0) "," else "", o.storePath() });
    try w.writeAll("],\"sources\":[");
    for (p.sources, 0..) |*x, i| try w.print("{s}\"{f}\"", .{ if (i > 0) "," else "", x });
    try w.print("],\"storeDrvs\":{d}}}\n", .{p.store_drvs});
    try render.write(s, out.written(), d);
    return 0;
}

// missing

const MissingFlags = struct {
    url: ?[]const u8 = null,
    status: bool = false,

    fn flag(f: *MissingFlags, a: *Args, x: []const u8) args_mod.Error!bool {
        if (std.mem.eql(u8, x, "--builder")) {
            f.url = try a.next(x);
        } else if (std.mem.eql(u8, x, "--check-cache-status")) {
            f.status = true;
        } else return false;
        return true;
    }
};

fn opMissing(c: *const cli.Ctx, a: *Args, argv: []const []const u8) args_mod.Error!u8 {
    var f: MissingFlags = .{};
    const r = try roots(c, a, try splitFlags(a, argv, &f));
    const s = c.s;
    var d: Diag = .init(s.gpa);
    defer d.deinit();
    return missing(c, a.arena, &r, f, &d) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => fail(s, &d, e),
    };
}

fn missing(c: *const cli.Ctx, a: Allocator, r: *const Roots, f: MissingFlags, d: *Diag) !u8 {
    const s = c.s;
    const env = c.init.environ_map;
    const transport = try apibuild.transport(a, s, env, f.url, d);
    var table: apibuild.DrvTable = .init(s.gpa);
    defer table.deinit();
    var p = try planOf(s, a, r, &table, d);
    var prov: Provenance = .off(s.gpa);
    defer prov.deinit();
    var x = apibuild.Dispatch.open(s, env, &transport, .default(), p, &prov, .detect(&s.log), d) catch |e| {
        p.deinit();
        return e;
    };
    defer x.deinit();
    const got = try x.missing(a, r.targets, d);
    var m = try Missing.of(a, got, &x.plan);
    if (f.status) m.roots = try cacheStatus(c, a, &transport, r.targets, d);
    var out: Writer.Allocating = .init(s.gpa);
    defer out.deinit();
    try m.json(&out.writer);
    try out.writer.writeByte('\n');
    try render.write(s, out.written(), d);
    return 0;
}

/// `--check-cache-status`, per root: the verdict `eval-jobs` reports, from
/// the derivations in `/nix/store`; raw JSON in `a`.
fn cacheStatus(c: *const cli.Ctx, a: Allocator, transport: *const worker.Transport, targets: []const Target, d: *Diag) ![]const u8 {
    const s = c.s;
    const gpa = s.gpa;
    var lines: std.ArrayList(jobs.Line) = .empty;
    defer {
        for (lines.items) |*l| l.deinit(gpa);
        lines.deinit(gpa);
    }
    for (targets) |t| {
        const drv = drv_mod.loadDerivationFromStore(s.io, a, t.drv, d) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Store,
        };
        try lines.ensureUnusedCapacity(gpa, 1);
        var job: jobs.Job = .{ .attr = try gpa.dupe(u8, t.attr), .attr_path = &.{}, .drv_path = t.drv };
        errdefer job.deinit(gpa);
        for (drv.outputs) |o| try job.putOutput(gpa, o.name, drv.outputPath(o.name, d) catch return error.Store);
        lines.appendAssumeCapacity(.{ .job = job });
    }
    var resolver = try jobs.cache.Resolver.open(gpa, s.io, transport, c.init.environ_map, d);
    defer resolver.deinit();
    try resolver.resolve(lines.items, d);
    var out: Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.writeByte('[');
    for (lines.items, 0..) |*l, i| {
        const j = &l.job;
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"cacheStatus\":{s},\"drv\":\"{f}\",\"neededBuilds\":{s},\"neededSubstitutes\":{s}}}", .{
            j.getExtra("cacheStatus") orelse "null",
            &j.drv_path,
            j.getExtra("neededBuilds") orelse "null",
            j.getExtra("neededSubstitutes") orelse "null",
        });
    }
    try w.writeByte(']');
    return out.written();
}

// build

const BuildFlags = struct {
    url: ?[]const u8 = null,
    outputs: std.ArrayList([]const u8) = .empty,
    sources: locate.Overrides = .empty,
    fetch_to: ?[]const u8 = null,
    gc_root: ?[]const u8 = null,
    no_build: bool = false,

    fn flag(f: *BuildFlags, a: *Args, x: []const u8) args_mod.Error!bool {
        const eql = std.mem.eql;
        if (eql(u8, x, "--builder")) {
            f.url = try a.next(x);
        } else if (eql(u8, x, "--out")) {
            try f.outputs.append(a.arena, try a.next(x));
        } else if (eql(u8, x, "--fetch-to")) {
            f.fetch_to = try a.next(x);
        } else if (eql(u8, x, "--gc-root")) {
            f.gc_root = try a.next(x);
        } else if (eql(u8, x, "--no-build")) {
            f.no_build = true;
        } else if (eql(u8, x, "--source")) {
            const spec = try a.next(x);
            const eq = std.mem.indexOfScalar(u8, spec, '=') orelse return a.fail("--source wants STOREPATH=LOCAL, got '{s}'", .{spec});
            try f.sources.put(a.arena, spec[0..eq], spec[eq + 1 ..]);
        } else return false;
        return true;
    }
};

fn opBuild(c: *const cli.Ctx, a: *Args, argv: []const []const u8) args_mod.Error!u8 {
    var f: BuildFlags = .{};
    const r = try roots(c, a, try splitFlags(a, argv, &f));
    if (f.outputs.items.len > 0) for (r.targets) |*t| {
        var list: std.ArrayList([]const u8) = try .initCapacity(a.arena, t.outputs.len + f.outputs.items.len);
        list.appendSliceAssumeCapacity(t.outputs);
        for (f.outputs.items) |name| try addName(a.arena, &list, name);
        t.outputs = list.items;
    };
    const s = c.s;
    var d: Diag = .init(s.gpa);
    defer d.deinit();
    return build(c, a.arena, &f, &r, &d) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => fail(s, &d, e),
    };
}

fn build(c: *const cli.Ctx, a: Allocator, f: *const BuildFlags, r: *const Roots, d: *Diag) !u8 {
    const s = c.s;
    const env = c.init.environ_map;
    const transport = try apibuild.transport(a, s, env, f.url, d);
    var table: apibuild.DrvTable = .init(s.gpa);
    defer table.deinit();
    var p = try planOf(s, a, r, &table, d);
    var prov: Provenance = .off(s.gpa);
    defer prov.deinit();
    var x = apibuild.Dispatch.open(s, env, &transport, .default(), p, &prov, .detect(&s.log), d) catch |e| {
        p.deinit();
        return e;
    };
    defer x.deinit();
    x.overrides = f.sources;
    if (f.no_build) {
        try x.uploadOnly(try r.paths(a), d);
        try render.write(s, "{\"outcomes\":[]}\n", d);
        return 0;
    }
    const outcomes = try x.submit(r.targets, d);
    if (f.fetch_to) |dir| for (outcomes) |oc| for (oc.outputs) |o| try x.d.fetch(o.path, dir, d);
    var gc_roots: ?[]const []const u8 = null;
    if (f.gc_root) |dir| {
        // the links go on the local daemon whatever the builder is, which is
        // what brings the outputs back here (docs/reference/classic.md)
        var links: std.ArrayList(backend.Link) = .empty;
        var names: std.ArrayList([]const u8) = .empty;
        for (outcomes) |oc| for (oc.outputs) |o| {
            var pd: Diag = .init(a);
            const base = if (StorePath.parse(o.path, &pd)) |sp| sp.baseName() else |_| o.path;
            const link = try joinPath(a, dir, base);
            try names.append(a, link);
            try links.append(a, .{ .path = o.path, .link = link });
        };
        try x.d.outLinks(links.items, d);
        gc_roots = names.items;
    }
    var out: Writer.Allocating = .init(s.gpa);
    defer out.deinit();
    try (Outcomes{ .items = outcomes, .gc_roots = gc_roots }).json(&out.writer);
    try out.writer.writeByte('\n');
    try render.write(s, out.written(), d);
    return @intCast(x.d.exit);
}

/// `dir`/`name`; an absolute `name` replaces `dir`.
fn joinPath(a: Allocator, dir: []const u8, name: []const u8) ![]const u8 {
    if (dir.len == 0 or std.mem.startsWith(u8, name, "/")) return name;
    if (dir[dir.len - 1] == '/') return std.mem.concat(a, u8, &.{ dir, name });
    return std.mem.concat(a, u8, &.{ dir, "/", name });
}

// fetch

/// A URL is a positional this op fetches itself; anything else is an
/// installable, which `parseEvalArgs` reads.
pub fn isUrl(s: []const u8) bool {
    // `file:/abs` is one slash and libcurl reads it, so `file:/` covers all three
    for ([_][]const u8{ "https://", "http://", "file:/" }) |p| if (std.mem.startsWith(u8, s, p)) return true;
    return false;
}

fn opFetch(c: *const cli.Ctx, a: *Args, argv: []const []const u8) args_mod.Error!u8 {
    const f = try fetchFlags(a, argv);
    return fetch(c, a, f, true);
}

/// The flags `fetch` and `iets prefetch` share, and what is left of the argv.
pub const FetchFlags = struct {
    unpack: bool = false,
    algo: hash_mod.Algo = .sha256,
    rest: []const []const u8 = &.{},
};

pub fn fetchFlags(a: *Args, argv: []const []const u8) args_mod.Error!FetchFlags {
    const eql = std.mem.eql;
    var f: FetchFlags = .{};
    var rest: std.ArrayList([]const u8) = .empty;
    a.argv = argv;
    a.i = 0;
    while (a.i < argv.len) : (a.i += 1) {
        const x = argv[a.i];
        if (eql(u8, x, "--unpack")) {
            f.unpack = true;
        } else if (eql(u8, x, "--hash-type")) {
            const v = try a.next(x);
            f.algo = hash_mod.Algo.parse(v) orelse return a.fail("unknown hash algorithm '{s}'", .{v});
        } else try rest.append(a.arena, x);
    }
    f.rest = rest.items;
    return f;
}

/// A URL or an installable becomes a hash: the whole of both frontends
/// past their own flags. `json` picks `Fetched`'s JSON over the hash alone.
pub fn fetch(c: *const cli.Ctx, a: *Args, f: FetchFlags, json: bool) args_mod.Error!u8 {
    var rest: std.ArrayList([]const u8) = .fromOwnedSlice(try a.arena.dupe([]const u8, f.rest));
    const at = for (rest.items, 0..) |x, i| {
        if (isUrl(x)) break i;
    } else {
        if (rest.items.len == 0) return a.fail("nothing to fetch: give a URL, -E EXPR, FILE or FLAKEREF#ATTR", .{});
        if (f.unpack) return a.fail("--unpack applies to a URL; a derivation says how it is hashed", .{});
        const p = try args_mod.parseEvalArgs(a, rest.items);
        const ea = try a.arena.create(EvalArgs);
        ea.* = p.eval;
        const run: Run = .{ .s = c.s, .init = c.init, .args = ea };
        const job: DrvJob = .{ .run = &run, .json = json };
        return run.go(&job, DrvJob.go);
    };
    const url = rest.orderedRemove(at);
    // what is left are flags only (--log-format, --show-trace, …)
    _ = try args_mod.parseEvalArgs(a, rest.items);
    const s = c.s;
    var d: Diag = .init(s.gpa);
    defer d.deinit();
    const h = api.fetch.urlHash(s, url, f.unpack, f.algo, &d) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            // Rust iets reports the OS error here without the
            // ` (os error N)` the download's own text carries
            if (d.msg) |m| if (std.mem.lastIndexOf(u8, m, " (os error ")) |i| if (std.mem.endsWith(u8, m, ")")) {
                d.msg = d.gpa.realloc(m, i) catch m;
            };
            return fail(s, &d, e);
        },
    };
    var buf: [hash_mod.Hash.max_string_len]u8 = undefined;
    return hashLine(s, json, h.print(&buf, .sri, true), "url", url);
}

/// One line on stdout: the hash and where it came from, as JSON or as the
/// hash alone.
fn hashLine(s: *Session, json: bool, hash: []const u8, key: []const u8, origin: []const u8) u8 {
    const f: api.render.Fetched = .{ .hash = hash, .key = key, .origin = origin };
    var out: Writer.Allocating = .init(s.gpa);
    defer out.deinit();
    var d: Diag = .init(s.gpa);
    defer d.deinit();
    (if (json) f.json(&out.writer) else f.text(&out.writer)) catch return fail(s, &d, error.OutOfMemory);
    if (json) out.writer.writeByte('\n') catch return fail(s, &d, error.OutOfMemory);
    render.write(s, out.written(), &d) catch |e| return fail(s, &d, e);
    return 0;
}

/// The hash the one fixed-output derivation an installable names really
/// produces. `iets prefetch` is the other frontend.
const DrvJob = struct {
    run: *const Run,
    json: bool,

    fn go(j: *const DrvJob, ev: *Evaluator) !u8 {
        const s = j.run.s;
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const v = try api.evaluate(ev, arena, j.run.args, try j.run.cwd());
        var roots_: std.ArrayList(installable.DrvRoot) = .empty;
        try installable.drvRoots(ev, arena, v, &roots_);
        if (roots_.items.len != 1) {
            const r: Report = .{ .code = "usage", .raw = try std.fmt.allocPrint(arena, "fetch wants one derivation, got {d}", .{roots_.items.len}) };
            return r.emit(&s.log);
        }
        var d: Diag = .init(s.gpa);
        defer d.deinit();
        const got, const p = api.fetch.drvHash(ev, s, j.run.init.environ_map, arena, roots_.items[0].drv, &d) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return fail(s, &d, e),
        };
        return hashLine(s, j.json, got, "drvPath", try std.fmt.allocPrint(arena, "{f}", .{&p}));
    }
};

/// serde_json's message for the first error in `text`, as Rust iets's
/// `from_str` gives it, `MSG at line L column C`; null when it parses.
fn serdeError(a: Allocator, text: []const u8) Allocator.Error!?[]const u8 {
    var p: Serde = .{ .t = text };
    p.value(0) catch {};
    if (p.err == null) if (p.peek() != null) p.fail("trailing characters", p.i + 1);
    const e = p.err orelse return null;
    var line: usize = 1;
    var start: usize = 0;
    for (text[0..e.at], 0..) |ch, k| if (ch == '\n') {
        line += 1;
        start = k + 1;
    };
    return try std.fmt.allocPrint(a, "{s} at line {d} column {d}", .{ e.msg, line, e.at - start });
}

/// A JSON reader that fails where serde_json fails, with its message and
/// the byte offset whose line and column serde reports.
const Serde = struct {
    t: []const u8,
    i: usize = 0,
    err: ?struct { msg: []const u8, at: usize } = null,

    const Fail = error{Json};

    fn fail(p: *Serde, msg: []const u8, at: usize) void {
        if (p.err == null) p.err = .{ .msg = msg, .at = @min(at, p.t.len) };
    }

    fn bad(p: *Serde, msg: []const u8, at: usize) Fail {
        p.fail(msg, at);
        return error.Json;
    }

    fn peek(p: *Serde) ?u8 {
        while (p.i < p.t.len and std.mem.indexOfScalar(u8, " \t\n\r", p.t[p.i]) != null) p.i += 1;
        return if (p.i < p.t.len) p.t[p.i] else null;
    }

    fn value(p: *Serde, depth: usize) Fail!void {
        const c = p.peek() orelse return p.bad("EOF while parsing a value", p.i);
        switch (c) {
            'n' => return p.ident("null"),
            't' => return p.ident("true"),
            'f' => return p.ident("false"),
            '"' => {
                p.i += 1;
                return p.string();
            },
            '-', '0'...'9' => return p.number(),
            '[', '{' => {
                if (depth >= 127) return p.bad("recursion limit exceeded", p.i + 1);
                p.i += 1;
                return if (c == '[') p.list(depth + 1) else p.object(depth + 1);
            },
            else => return p.bad("expected value", p.i + 1),
        }
    }

    fn ident(p: *Serde, word: []const u8) Fail!void {
        p.i += 1;
        for (word[1..]) |ch| {
            if (p.i >= p.t.len) return p.bad("EOF while parsing a value", p.i);
            p.i += 1;
            if (p.t[p.i - 1] != ch) return p.bad("expected ident", p.i);
        }
    }

    fn digits(p: *Serde) usize {
        const s = p.i;
        while (p.i < p.t.len and std.ascii.isDigit(p.t[p.i])) p.i += 1;
        return p.i - s;
    }

    fn number(p: *Serde) Fail!void {
        if (p.t[p.i] == '-') p.i += 1;
        if (p.i >= p.t.len) return p.bad("EOF while parsing a value", p.i);
        if (p.t[p.i] == '0') {
            p.i += 1;
            if (p.i < p.t.len and std.ascii.isDigit(p.t[p.i])) return p.bad("invalid number", p.i + 1);
        } else if (p.digits() == 0) return p.bad("invalid number", p.i + 1);
        if (p.i < p.t.len and p.t[p.i] == '.') {
            p.i += 1;
            if (p.i >= p.t.len) return p.bad("EOF while parsing a value", p.i);
            if (p.digits() == 0) return p.bad("invalid number", p.i + 1);
        }
        if (p.i < p.t.len and (p.t[p.i] == 'e' or p.t[p.i] == 'E')) {
            p.i += 1;
            if (p.i < p.t.len and (p.t[p.i] == '+' or p.t[p.i] == '-')) p.i += 1;
            if (p.i >= p.t.len) return p.bad("EOF while parsing a value", p.i);
            if (p.digits() == 0) return p.bad("invalid number", p.i + 1);
        }
    }

    fn string(p: *Serde) Fail!void {
        while (true) {
            if (p.i >= p.t.len) return p.bad("EOF while parsing a string", p.i);
            const ch = p.t[p.i];
            p.i += 1;
            switch (ch) {
                '"' => return,
                '\\' => {
                    if (p.i >= p.t.len) return p.bad("EOF while parsing a string", p.i);
                    p.i += 1;
                    switch (p.t[p.i - 1]) {
                        '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => {},
                        'u' => for (0..4) |_| {
                            if (p.i >= p.t.len) return p.bad("EOF while parsing a string", p.i);
                            p.i += 1;
                            if (!std.ascii.isHex(p.t[p.i - 1])) return p.bad("invalid escape", p.i);
                        },
                        else => return p.bad("invalid escape", p.i),
                    }
                },
                0...0x1f => return p.bad("control character (\\u0000-\\u001F) found while parsing a string", p.i),
                else => {},
            }
        }
    }

    fn list(p: *Serde, depth: usize) Fail!void {
        var first = true;
        while (true) {
            var c = p.peek() orelse return p.bad("EOF while parsing a list", p.i);
            if (c == ']') {
                p.i += 1;
                return;
            }
            if (!first) {
                if (c != ',') return p.bad("expected `,` or `]`", p.i + 1);
                p.i += 1;
                c = p.peek() orelse return p.bad("EOF while parsing a value", p.i);
                if (c == ']') return p.bad("trailing comma", p.i + 1);
            }
            first = false;
            try p.value(depth);
        }
    }

    fn object(p: *Serde, depth: usize) Fail!void {
        var first = true;
        while (true) {
            var c = p.peek() orelse return p.bad("EOF while parsing an object", p.i);
            if (c == '}') {
                p.i += 1;
                return;
            }
            if (!first) {
                if (c != ',') return p.bad("expected `,` or `}`", p.i + 1);
                p.i += 1;
                c = p.peek() orelse return p.bad("EOF while parsing a value", p.i);
                if (c == '}') return p.bad("trailing comma", p.i + 1);
            }
            first = false;
            if (c != '"') return p.bad("key must be a string", p.i + 1);
            p.i += 1;
            try p.string();
            const colon = p.peek() orelse return p.bad("EOF while parsing an object", p.i);
            if (colon != ':') return p.bad("expected `:`", p.i + 1);
            p.i += 1;
            try p.value(depth);
        }
    }
};

const testing = std.testing;

test "a file URL needs one slash, not three" {
    // libcurl reads `file:/abs`, and a lock file may hold that form
    const cases = .{
        .{ "file:/a/b", true },  .{ "file:///a/b", true }, .{ "file://localhost/a/b", true },
        .{ "http://x/y", true }, .{ "https://x/y", true }, .{ "/a/b", false },
        .{ "./a", false },       .{ "a/b", false },        .{ "fil:/a", false },
    };
    inline for (cases) |c| try testing.expectEqual(c[1], isUrl(c[0]));
}

test "a URL is the positional fetch takes itself" {
    try testing.expect(isUrl("file:///tmp/a.tar.gz"));
    try testing.expect(isUrl("https://example.org/a.tar.gz"));
    try testing.expect(!isUrl("github:numtide/treefmt"));
    try testing.expect(!isUrl("./default.nix"));
}

test "stdin that is not JSON fails as serde_json says" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = .{
        .{ "\n", "EOF while parsing a value at line 2 column 0" },
        .{ "{\n", "EOF while parsing an object at line 2 column 0" },
        .{ "x", "expected value at line 1 column 1" },
        .{ "{} x", "trailing characters at line 1 column 4" },
        .{ "[1,]", "trailing comma at line 1 column 4" },
        .{ "{\"a\" 1}", "expected `:` at line 1 column 6" },
        .{ "tru", "EOF while parsing a value at line 1 column 3" },
        .{ "[\"a", "EOF while parsing a string at line 1 column 3" },
    };
    inline for (cases) |c| try testing.expectEqualStrings(c[1], (try serdeError(a, c[0])).?);
    try testing.expectEqual(null, try serdeError(a, "{\"roots\":[{\"drv\":\"x\",\"output\":null}],\"n\":-1.5e3}\n"));
}

test "a link joins as Path::join does" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("gc/x", try joinPath(a, "gc", "x"));
    try testing.expectEqualStrings("gc/x", try joinPath(a, "gc/", "x"));
    try testing.expectEqualStrings("/abs", try joinPath(a, "gc", "/abs"));
}
