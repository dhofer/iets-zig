//! `iets eval`: evaluate an expression and print it. A repeated run is answered from the tracing
//! cache: the entry holds the printed output.

const std = @import("std");
const Io = std.Io;
const cli = @import("../cli.zig");
const help = @import("help.zig");
const args_mod = @import("args.zig");
const api = @import("../api.zig");
const Evaluator = @import("../eval/Evaluator.zig");
const print = @import("../eval/print.zig");
const value = @import("../runtime/value.zig");
const Value = value.Value;
const cachefs = @import("../cachefs.zig");
const treestore = @import("../treestore.zig");

/// `iets eval FLAGS (-E EXPR | FILE)`.
pub fn cmd(c: *const cli.Ctx, argv: []const []const u8) u8 {
    var a: args_mod.Args = .{ .s = c.s, .arena = c.init.arena.allocator(), .cmd = "eval", .argv = argv };
    const p = args_mod.parseEvalArgs(&a, argv) catch |e| return a.report(e);
    return run(c, &p.eval);
}

/// `iets eval` with its arguments parsed.
pub fn run(c: *const cli.Ctx, ea: *const api.EvalArgs) u8 {
    const s = c.s;
    const tcache = api.cache.open(s, c.init, ea, "eval", &.{}) catch null;
    defer if (tcache) |tc| tc.deinit();
    if (tcache) |tc| if (hit(c, tc, ea.cache_dir)) |code| return code;
    const r: api.run.Run = .{
        .s = s,
        .init = c.init,
        .args = ea,
        // only the cache and --dump-drvs read the ATerm text after evaluation
        .keep_aterm = tcache != null or ea.dump_drvs != null,
        .keep_site = false,
        .cache = tcache,
    };
    var job: Job = .{ .c = c, .r = &r, .cache = tcache };
    defer job.out.deinit(s.gpa);
    return r.go(&job, Job.evalAndPrint);
}

/// The recorded output when the entry is still good; the exit code.
fn hit(c: *const cli.Ctx, tc: *api.cache.Cache, cache_dir: ?[]const u8) ?u8 {
    const s = c.s;
    const arena = c.init.arena.allocator();
    // the input store the read set's `Input` observations are in
    const root = (cachefs.root(arena, c.init.environ_map, cache_dir orelse s.settings.cache_dir) catch null) orelse null;
    var inputs: treestore.Store = .init(s.gpa, s.io, if (root) |r| (treestore.locate(arena, r) catch null) else null);
    defer inputs.deinit();
    tc.inputs = .{ .ctx = &inputs, .has = struct {
        fn has(ctx: *anyopaque, name: []const u8, version: u8) bool {
            const st: *treestore.Store = @ptrCast(@alignCast(ctx));
            return st.has(name, version);
        }
    }.has };
    defer tc.inputs = null;
    if (!(tc.lookup() catch false)) return null;
    const out = tc.part(.result) orelse return null;
    if (tc.replayedNixConfig()) s.ignored.nixConfigSeen();
    tc.replayWarnings() catch {};
    s.out.writeAll(out) catch return help.writeFailed(s, out.len);
    return 0;
}

const Job = struct {
    c: *const cli.Ctx,
    r: *const api.run.Run,
    cache: ?*api.cache.Cache = null,
    /// Everything printed, for the cache entry.
    out: std.ArrayList(u8) = .empty,
    /// A write to stdout failed: its report's exit code.
    write_failed: ?u8 = null,

    fn evalAndPrint(j: *Job, ev: *Evaluator) !u8 {
        const s = j.c.s;
        const a = j.r.args;
        // `api::evaluate_each` with a missing input reported as a usage error
        if (a.input == null) return help.argError(s, "nothing to evaluate: give -E EXPR or FILE");
        const arena = j.c.init.arena.allocator();
        const t0 = Io.Clock.awake.now(ev.io);
        const act = try api.evaluating(s, arena, a);
        const cwd = try j.r.cwd();
        const r = api.evaluateEach(ev, arena, a, cwd, j, each);
        act.end();
        if (s.settings.stats >= 1) api.printStats(ev, j.c.init.environ_map);
        if (j.write_failed) |code| return code;
        try r;
        if (a.timings) {
            const ns: u64 = @intCast(t0.durationTo(Io.Clock.awake.now(ev.io)).toNanoseconds());
            var buf: [64]u8 = undefined;
            s.log.err(std.fmt.bufPrint(&buf, "eval: {d:.3}s\n", .{@as(f64, @floatFromInt(ns)) / 1e9}) catch "");
            if (ev.config.inputs) |inputs| {
                var err_log: api.run.LogWriter = .{ .log = &s.log };
                inputs.reportTimings(&err_log.interface);
            }
        }
        if (j.cache) |tc| try api.cache.writeEntry(tc, s, ev, j.out.items, false);
        return 0;
    }

    /// One value, printed as it is made, as in `nix-instantiate --eval`.
    fn each(j: *Job, ev: *Evaluator, v: Value) Evaluator.Error!void {
        const a = j.r.args;
        var out: Io.Writer.Allocating = .init(ev.gpa);
        defer out.deinit();
        const w = &out.writer;
        if (a.raw) {
            // nix eval --raw: coerce without copying to the store, no newline
            var bytes: std.ArrayList(u8) = .empty;
            defer bytes.deinit(ev.gpa);
            var ctx: std.ArrayList(value.Ctx) = .empty;
            defer ctx.deinit(ev.gpa);
            try ev.coerceToString(v, &bytes, &ctx, .none, "while generating the eval command output", .{ .copy_to_store = false });
            w.writeAll(bytes.items) catch return error.OutOfMemory;
        } else if (a.json) {
            // nix eval --json forces the whole value, --strict or not (eval.cc)
            var ctx: std.ArrayList(value.Ctx) = .empty;
            defer ctx.deinit(ev.gpa);
            print.writeJson(ev, w, v, &ctx, true, .none) catch |e| return print.inMemory(e);
        } else {
            const forced = if (a.strict) try ev.forceDeep(v) else try ev.force(v);
            print.writeAmbiguous(ev, w, forced) catch |e| return print.inMemory(e);
        }
        if (!a.raw) w.writeByte('\n') catch return error.OutOfMemory;
        if (j.cache != null) try j.out.appendSlice(j.c.s.gpa, out.written());
        j.c.s.out.writeAll(out.written()) catch {
            j.write_failed = help.writeFailed(j.c.s, out.written().len);
            return error.EvalFailed;
        };
    }
};
