//! One run of one command: the evaluator configuration and the parallel
//! entry.
//!
//! The tracing cache of the subcommand is the caller's to open
//! (`api/cache.zig`) and hand in as `cache`: the run records into it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Evaluator = @import("../eval/Evaluator.zig");
const Session = @import("../session.zig").Session;
const api = @import("../api.zig");
const EvalArgs = api.EvalArgs;
const Heap = @import("../Heap.zig");
const fault = @import("../sys/fault.zig");
const syntax = @import("../syntax.zig");
const Files = @import("../eval/Files.zig");
const builtins = @import("../builtins.zig");
const project = @import("../project.zig");
const profile = @import("../profile.zig");
const cachefs = @import("../cachefs.zig");
const IrCache = @import("../ir_cache.zig").IrCache;
const value = @import("../runtime/value.zig");
const lint = @import("../lint.zig");
const treestore = @import("../treestore.zig");

/// A run's frame: what the command keeps between its evaluation and its
/// build. Everything in `arena` lives as long as the process.
pub const Run = struct {
    s: *Session,
    init: *const std.process.Init,
    args: *const EvalArgs,
    /// Keep every derivation's ATerm: a build plans from them.
    keep_aterm: bool = true,
    /// Record where each derivation was defined, for the build's names.
    keep_site: bool = true,
    /// Classic mode's evaluator configuration, from nix.conf; null for iets's own commands.
    classic: ?*const Classic = null,
    /// Where an `unsupported` evaluation error goes instead of its report,
    /// so a classic command can fall back to the real nix.
    fallback: ?*Fallback = null,
    /// The tracing cache this run writes an entry to: the evaluation
    /// records its read set.
    cache: ?*@import("../trace.zig").run.Cache = null,
    /// The search path, in place of `-I` and `NIX_PATH` from `args`: a
    /// classic command's (`full_includes`).
    search_path: ?[]const Evaluator.SearchPathEntry = null,
    /// The lint configuration, in place of the one `args` resolves: classic
    /// commands lint nothing.
    lints: ?*const lint.Config = null,

    /// The working directory, in the process arena.
    pub fn cwd(r: *const Run) ![]const u8 {
        return std.process.currentPathAlloc(r.init.io, r.init.arena.allocator());
    }

    /// `f(ctx, ev)` as the main fiber of the run's evaluator threads, on a
    /// stack deep enough for Nix programs: `f` returns the exit code, or an
    /// error of its own set. Its evaluation error is reported here and
    /// becomes the exit code; another error is printed as its name, exit
    /// code 1.
    pub fn go(r: *const Run, ctx: anytype, comptime f: anytype) u8 {
        const C = @TypeOf(ctx);
        const Job = struct {
            r: *const Run,
            ctx: C,
            result: u8 = 1,
            fn thread(j: *@This()) void {
                // A one-worker run overflows this stack, not a fiber's: report it
                // as Rust iets does for its threads, from a signal stack of its own.
                var alt: [fault.alt_size]u8 align(16) = undefined;
                const old = fault.altStack(&alt);
                defer fault.restoreAltStack(old);
                const token = fault.guardThread();
                defer fault.unguardThread(token);
                j.result = j.r.main(j.ctx, f) catch |e| blk: {
                    j.r.s.log.errln(std.fmt.allocPrint(j.r.init.arena.allocator(), "error: {s}", .{@errorName(e)}) catch "error");
                    break :blk 1;
                };
            }
        };
        var job: Job = .{ .r = r, .ctx = ctx };
        // Nix programs recurse deeply; the evaluator gets a stack to match.
        const t = std.Thread.spawn(.{ .stack_size = api.main_stack }, Job.thread, .{&job}) catch {
            r.s.log.errln("error: cannot start the evaluator thread");
            return 1;
        };
        t.join();
        return job.result;
    }

    fn main(r: *const Run, ctx: anytype, comptime f: anytype) !u8 {
        // Debug builds check every allocation; release builds take `Heap`.
        var dbg: std.heap.DebugAllocator(.{}) = .init;
        defer if (@import("builtin").mode == .debug) {
            _ = dbg.deinit();
        };
        const gpa = if (@import("builtin").mode == .debug) dbg.allocator() else Heap.allocator;
        const s = r.s;
        const a = r.args;
        const init = r.init;
        const arena = init.arena.allocator();
        const io = init.io;
        const pure = if (r.classic) |c| c.pure else a.pure orelse s.settings.pure;

        const cwd_ = try r.cwd();
        const search = if (r.classic) |c| c.search_path else try api.searchPath(arena, cwd_, a.includes, if (pure) null else init.environ_map.get("NIX_PATH"), null);
        // A pure evaluation reads below the project the entry belongs to.
        const project_root = try api.projectRoot(arena, io, a, cwd_);

        if (a.dump_drvs) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch |e| {
            const msg = try std.fmt.allocPrint(arena, "cannot create '{s}': {s}", .{ dir, @import("../errors.zig").ioText(e) });
            const rep: @import("../log.zig").Report = .{ .code = "io", .raw = msg };
            return rep.emit(&s.log);
        };

        var recorder: @import("../trace.zig").Recorder = .init(gpa, io, if (r.cache) |c| &c.store else null);
        defer recorder.deinit();

        var interner: syntax.Interner = try .init(gpa);
        defer interner.deinit();
        var files: Files = .init(gpa, io);
        var shared: Evaluator.Shared = .{};
        defer shared.deinit(gpa);
        defer files.deinit();
        var local: Evaluator.Local = .init(gpa);
        defer local.deinit();
        value.flat_arena = &local.arena;
        defer value.flat_arena = null;
        var ev: Evaluator = try .init(gpa, io, &local, &interner, &files, &shared, .{
            .pure = pure,
            .search_path = r.search_path orelse search,
            .home = init.environ_map.get("HOME") orelse "/",
            .cwd = cwd_,
            .lints = r.lints orelse if (r.classic != null) &lint.Config.off else (try lintConfig(r, cwd_)) orelse return 1,
            .system = if (r.classic) |c| c.system else (Evaluator.Config{}).system,
            .parse_toml_timestamps = a.tomlTimestamps(),
            // classic mode configures none: a pure run reads no local file, as in Nix
            .project_root = if (r.classic != null) null else project_root,
            .keep_aterm = r.keep_aterm,
            .keep_site = r.keep_site,
            .dump_dir = a.dump_drvs,
            .session = s,
            .trace = if (r.cache != null) recorder.handle() else .off,
        });
        defer ev.deinit();
        // The library writes nothing to stderr by itself: what the
        // evaluator prints goes to the session's log.
        var err_log: LogWriter = .{ .log = &s.log };
        ev.stderr = &err_log.interface;
        shared.lints.out = &err_log.interface;
        defer lint.report.flush(&ev);
        var prof_stack: profile.Stack = .{ .profile = &s.profile };
        defer prof_stack.deinit(gpa);
        if (s.profile.on()) {
            ev.setProfile(&prof_stack);
            s.profile.names(&files, &interner);
        }
        // written while the files and the interner that name its frames live
        defer s.profile.write(&s.log);
        var cache = try openIrCache(init, a, s, gpa, &err_log.interface);
        defer if (cache) |*c| c.close();
        if (cache) |*c| ev.config.ir_cache = c;
        // the input store fetched trees live in, and what a download may do
        const inputs_root = try @import("../treestore.zig").locate(arena, try cachefs.root(arena, init.environ_map, a.cache_dir orelse s.settings.cache_dir));
        var inputs: @import("../treestore.zig").Store = .init(gpa, io, inputs_root);
        defer inputs.deinit();
        inputs.stderr = &err_log.interface;
        ev.config.inputs = &inputs;
        ev.config.fetch_limits = @import("../cli/prefetch.zig").limits(s);
        ev.config.offline = s.settings.offline;
        try builtins.store_hooks.prefetchSearchPath(&ev);
        // The default is the cores, at most 4: past that the demand path's
        // wait for other threads' thunks decides the wall time.
        const workers: u32 = if (a.workers > 0) a.workers else if (s.settings.workers) |w| @intCast(w) else @intCast(@min(4, std.Thread.getCpuCount() catch 1));

        try builtins.install(&ev);
        const C = @TypeOf(ctx);
        const Job = struct {
            ctx: C,
            result: @typeInfo(@TypeOf(f)).@"fn".return_type.? = 1,
            fn go(e: *Evaluator, j: *@This()) void {
                j.result = f(j.ctx, e);
            }
        };
        var job: Job = .{ .ctx = ctx };
        // the helpers' arenas hold what the shared tables point into, which
        // a failure's report reads: the pool goes after the report
        var pool: ?*Evaluator.Pool = null;
        defer if (pool) |p| p.destroy();
        if (workers <= 1) {
            Job.go(&ev, &job);
        } else {
            // Helpers copy the globals, so they start once those are complete.
            ev.par.on = true;
            pool = try Evaluator.Pool.create(&ev, workers);
            try pool.?.run(Job.go, &job);
            if (s.settings.stats >= 1) ev.log("pool: {f}", .{&pool.?.stats});
        }
        return job.result catch |e| {
            // `f`'s own set may not hold it: compared as any error
            if (@as(anyerror, e) != error.EvalFailed) return e;
            lint.report.flush(&ev);
            if (r.fallback) |fb| if (ev.failure) |fl| if (fl.kind == .unsupported) {
                fb.why = try arena.dupe(u8, fl.msg);
                return 1;
            };
            return api.report(&ev, s, arena);
        };
    }
};

/// The `unsupported` error a run met instead of reporting it: why the
/// classic command falls back.
pub const Fallback = struct { why: ?[]const u8 = null };

/// What classic mode sets from nix.conf rather than from iets's settings.
pub const Classic = struct {
    system: []const u8,
    pure: bool,
    /// Absolute already: the `-I`s, `NIX_PATH` and `nix-path`.
    search_path: []const Evaluator.SearchPathEntry,
};

/// The lint configuration of a run: the entry's directory starts the
/// `iets.toml` walk and is the first lint root. Its
/// notes are warnings; a configuration that does not resolve is reported
/// and gives null.
pub fn lintConfig(r: *const Run, cwd: []const u8) !?*lint.Config {
    const arena = r.init.arena.allocator();
    var notes: lint.Notes = .{};
    var dg: @import("../diag.zig").Diag = .init(arena);
    const cfg = try arena.create(lint.Config);
    cfg.* = api.lintConfig(arena, r.init.io, .fromMap(r.init.environ_map), r.args, cwd, &notes, &dg) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.BadConfig => {
            try notes.give(&r.s.ignored);
            // an evaluation error without a position
            _ = (@import("../log.zig").Report{ .code = "eval", .raw = dg.message() }).emit(&r.s.log);
            return null;
        },
    };
    try notes.give(&r.s.ignored);
    return cfg;
}

/// A writer into a session's log: the evaluator's lines and the lint
/// warnings reach wherever the host pointed the log.
pub const LogWriter = struct {
    log: *@import("../log.zig").Log,
    interface: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const l: *LogWriter = @fieldParentPtr("interface", w);
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            l.log.err(d);
            n += d.len;
        }
        for (0..splat) |_| {
            l.log.err(data[data.len - 1]);
            n += data[data.len - 1].len;
        }
        return n;
    }
};

/// The IR cache unless `--no-ir-cache` or the `cache` setting says no, or
/// when the cache directory is unusable.
fn openIrCache(init: *const std.process.Init, a: *const EvalArgs, s: *Session, gpa: Allocator, stderr: *std.Io.Writer) !?IrCache {
    if (a.no_ir_cache or !s.settings.cache) return null;
    const root = try cachefs.root(init.arena.allocator(), init.environ_map, a.cache_dir orelse s.settings.cache_dir) orelse return null;
    var c = try IrCache.open(gpa, init.io, root, stderr) orelse return null;
    c.min_size = s.settings.ir_min;
    if (s.settings.ir_stats) c.stats = stderr;
    return c;
}
