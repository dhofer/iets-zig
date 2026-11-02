//! `iets eval-jobs`: flags, the three process roles, and the summary.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = Io.Writer;
const Diag = @import("../diag.zig").Diag;
const cli = @import("../cli.zig");
const args_mod = @import("args.zig");
const Args = args_mod.Args;
const Session = @import("../session.zig").Session;
const Stdout = @import("../stdout.zig").Stdout;
const log_mod = @import("../log.zig");
const Report = log_mod.Report;
const errors = @import("../errors.zig");
const ignored = @import("../ignored.zig");
const api = @import("../api.zig");
const EvalArgs = api.EvalArgs;
const Run = api.run.Run;
const Evaluator = @import("../eval/Evaluator.zig");
const import_ = @import("../eval/import.zig");
const value = @import("../runtime/value.zig");
const Value = value.Value;
const remote = @import("../remote.zig");
const worker = remote.worker;
const Transport = worker.Transport;
const Connection = worker.Connection;
const backend = @import("../build/backend.zig");
const locate = @import("../store/locate.zig");
const jobs = @import("../jobs.zig");
const Line = jobs.Line;
const Opts = jobs.Opts;
const Walk = jobs.Walk;
const Emitter = jobs.emit.Emitter;
const Resolver = jobs.cache.Resolver;
const instantiate = jobs.instantiate;
const Store = instantiate.Store;
const Instantiator = instantiate.Instantiator;
const collector = jobs.collector;

/// nix-eval-jobs's `MyArgs::DEFAULT_MAX_MEMORY_SIZE` (eval-args.hh:18): an
/// arena without a GC cannot shed a walked subtree, so the default needs
/// the same process boundary nix-eval-jobs has.
const default_max_memory_mb = 4096;

/// `iets eval-jobs`'s own flags; everything else goes to `parseEvalArgs`.
const JobsArgs = struct {
    opts: Opts = .{},
    check_cache_status: bool = false,
    gc_roots_dir: ?[]const u8 = null,
    eval_store: []const u8 = "daemon",
    apply: ?[]const u8 = null,
    select: ?[]const u8 = null,
    /// `--max-memory-size MB`: worker processes restarted above it;
    /// `0` is one process with no ceiling.
    max_memory: u64 = default_max_memory_mb,
    /// `--arg-from-stdin NAME`: the name and what was read, for the worker
    /// argv.
    stdin_args: std.ArrayList([2][]const u8) = .empty,
    worker: bool = false,
    flake: bool = false,
    /// Its own flag, not `EvalArgs.pure`: nix-eval-jobs.cc lets it beat `--flake`.
    impure: bool = false,
    quiet: bool = false,
};

/// The command's own flags, and the rest for `parseEvalArgs`.
const Parsed = struct { j: JobsArgs, rest: []const []const u8 };

/// `iets eval-jobs`'s own flags: the tag is the word.
const JobsFlag = enum {
    @"--force-recurse",
    @"--meta",
    @"--show-input-drvs",
    @"--no-instantiate",
    @"--constituents",
    @"--provenance",
    @"--check-cache-status",
    @"--chunks",
    @"--chunk",
    @"--chunk-depth",
    @"--max-memory-size",
    @"--apply",
    @"--select",
    @"--gc-roots-dir",
    @"--eval-store",
    @"--max-jobs",
    @"-j",
    @"--flake",
    @"--impure",
    @"--worker",
    @"--quiet",
    @"--verbose",
    @"--debug",
    @"--override-input",
    @"--override-flake",
    @"--repair",
    @"--arg-from-file",
    @"--arg-from-stdin",
    @"--include",
};

fn parseJobsArgs(a: *Args, argv: []const []const u8) args_mod.Error!Parsed {
    const s = a.s;
    const arena = a.arena;
    var j: JobsArgs = .{};
    var rest: std.ArrayList([]const u8) = .empty;
    a.argv = argv;
    a.i = 0;
    while (a.i < argv.len) : (a.i += 1) {
        const x = argv[a.i];
        const flag = std.meta.stringToEnum(JobsFlag, x) orelse {
            try rest.append(arena, x);
            continue;
        };
        switch (flag) {
            .@"--force-recurse" => j.opts.force_recurse = true,
            .@"--meta" => j.opts.meta = true,
            .@"--show-input-drvs" => j.opts.show_input_drvs = true,
            .@"--no-instantiate" => j.opts.no_instantiate = true,
            .@"--constituents" => j.opts.constituents = true,
            .@"--provenance" => j.opts.provenance = true,
            .@"--check-cache-status" => j.check_cache_status = true,
            .@"--chunks" => j.opts.chunks = @max(@as(u32, @truncate(try num(a, x))), 1),
            .@"--chunk" => j.opts.chunk = @truncate(try num(a, x)),
            .@"--chunk-depth" => j.opts.chunk_depth = @truncate(try num(a, x)),
            .@"--max-memory-size" => j.max_memory = try num(a, x),
            .@"--apply" => j.apply = try a.next(x),
            .@"--select" => j.select = try a.next(x),
            .@"--gc-roots-dir" => {
                const d = try a.next(x);
                const cwd = std.process.currentPathAlloc(s.io, arena) catch "/";
                j.gc_roots_dir = try api.absPath(arena, cwd, d);
            },
            .@"--eval-store" => j.eval_store = try a.next(x),
            // holds by construction: it caps the builds of an import from
            // derivation, and iets builds nothing while it evaluates
            .@"--max-jobs", .@"-j" => _ = try a.next(x),
            .@"--flake" => j.flake = true,
            .@"--impure" => j.impure = true,
            .@"--worker" => j.worker = true,
            .@"--quiet" => j.quiet = true,
            .@"--verbose", .@"--debug" => s.ignored.flag(x, ignored.one_log_level) catch {},
            .@"--override-input", .@"--override-flake" => return a.reported(unsupported(s, x, "iets evaluates locked flakes only; an override makes the lock file incomplete")),
            .@"--repair" => return a.reported(unsupported(s, x, "iets does not write or repair store paths")),
            .@"--arg-from-file" => {
                const name = try a.next(x);
                const path = try a.next(x);
                const contents = Io.Dir.cwd().readFileAlloc(s.io, path, arena, .unlimited) catch |e|
                    return a.reported(fail(s, error.Io, try std.fmt.allocPrint(arena, "cannot read '{s}': {s}", .{ path, errors.ioText(e) })));
                try rest.appendSlice(arena, &.{ "--argstr", name, contents });
            },
            .@"--arg-from-stdin" => {
                const name = try a.next(x);
                var buf: [4096]u8 = undefined;
                var r = Io.File.stdin().readerStreaming(s.io, &buf);
                const contents = r.interface.allocRemaining(arena, .unlimited) catch
                    return a.reported(fail(s, error.Io, "cannot read stdin: Input/output error"));
                try rest.appendSlice(arena, &.{ "--argstr", name, contents });
                try j.stdin_args.append(arena, .{ name, contents });
            },
            .@"--include" => try rest.appendSlice(arena, &.{ "-I", try a.next(x) }),
        }
    }
    return .{ .j = j, .rest = rest.items };
}

fn num(a: *Args, flag: []const u8) args_mod.Error!u64 {
    const v = try a.next(flag);
    return std.fmt.parseInt(u64, v, 10) catch a.fail("{s} wants a number, got '{s}'", .{ flag, v });
}

fn unsupported(s: *Session, flag: []const u8, why: []const u8) u8 {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s} is not supported by iets: {s} ('iets help commands')", .{ flag, why }) catch why;
    return fail(s, error.Unsupported, msg);
}

/// Reports an error from outside the evaluator; the exit code.
fn fail(s: *Session, e: anyerror, msg: []const u8) u8 {
    const r: Report = .{ .code = errors.code(e), .raw = msg };
    return r.emit(&s.log);
}

fn failDiag(s: *Session, e: anyerror, d: *const Diag) u8 {
    const r = errors.report(e, d);
    return r.emit(&s.log);
}

/// A worker process's command line: `argv` with every `--arg-from-stdin`
/// replaced by the `--argstr` the main process read for it. A worker's
/// stdin is the collector's pipe, so it cannot read the value itself.
fn workerArgv(s: *Session, arena: Allocator, exe: []const u8, argv: []const []const u8, j: *const JobsArgs) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(arena, &.{ exe, "eval-jobs", "--worker" });
    // `--iets-option` left `argv` before this command saw it, and a worker
    // reads its own settings, so the triples go back on here
    try out.appendSlice(arena, try s.settings.optionArgv(arena));
    var read: usize = 0;
    var i: usize = 0;
    while (i < argv.len) {
        if (std.mem.eql(u8, argv[i], "--arg-from-stdin")) {
            if (read < j.stdin_args.items.len) {
                const p = j.stdin_args.items[read];
                read += 1;
                try out.appendSlice(arena, &.{ "--argstr", p[0], p[1] });
            }
            i += 2;
            continue;
        }
        try out.append(arena, argv[i]);
        i += 1;
    }
    return out.items;
}

/// nix-eval-jobs.cc:validateIncompatibleFlags.
fn checkJobsArgs(arena: Allocator, j: *const JobsArgs, env: ?*const std.process.Environ.Map, d: *Diag) !Transport {
    if (j.opts.chunk >= j.opts.chunks) return d.fail(error.Usage, "--chunk must be below --chunks", .{});
    if (j.opts.no_instantiate) {
        var bad: std.ArrayList([]const u8) = .empty;
        if (j.opts.show_input_drvs) try bad.append(arena, "--show-input-drvs");
        if (j.check_cache_status) try bad.append(arena, "--check-cache-status");
        if (j.opts.constituents) try bad.append(arena, "--constituents");
        if (bad.items.len > 0) return d.fail(error.Usage, "--no-instantiate is incompatible with: {s}. These features require instantiated derivations.", .{try std.mem.join(arena, ", ", bad.items)});
    }
    // the worker protocol's stores only: a `grpc://` store builds, it does
    // not take `.drv` files
    const t = Transport.parse(arena, j.eval_store, env);
    if (t == null or t.? == .grpc)
        return d.fail(error.Usage, "--eval-store '{s}': eval-jobs needs a Nix daemon: daemon, unix:///path or ssh-ng://host", .{j.eval_store});
    return t.?;
}

/// Everything a role needs, on the command's stack: it outlives the
/// evaluator and its workers.
const Cmd = struct {
    c: *const cli.Ctx,
    s: *Session,
    arena: Allocator,
    /// Owns the lines; thread-safe.
    gpa: Allocator,
    io: Io,
    a: EvalArgs,
    j: JobsArgs,
    transport: Transport,
    t0: u64,
    walk: Walk,
    cwd: []const u8,

    fn env(x: *const Cmd) *const std.process.Environ.Map {
        return x.c.init.environ_map;
    }

    fn cx(x: *const Cmd) backend.Context {
        return .{ .gpa = x.gpa, .io = x.io, .env = x.env(), .log = .of(&x.s.log) };
    }

    fn nix(x: *const Cmd) locate.Nix {
        return .{ .io = x.io, .env = x.s.env };
    }
};

/// `iets eval-jobs`: nix-eval-jobs's JSON lines. Worker processes
/// restarted above `--max-memory-size` (4096 MB, like nix-eval-jobs);
/// `--max-memory-size 0` is one process with no ceiling.
/// See docs/reference/commands.md.
pub fn cmd(c: *const cli.Ctx, argv: []const []const u8) u8 {
    const s = c.s;
    // classic mode has no iets command (cli/classic/mod.zig)
    if (!s.log.isClassic()) s.log.command = "eval-jobs";
    const arena = c.init.arena.allocator();
    var args: Args = .{ .s = s, .arena = arena, .cmd = "eval-jobs", .argv = argv, .native = !s.log.isClassic() };
    const p = parseJobsArgs(&args, argv) catch |e| return args.report(e);
    const j = p.j;
    if (j.worker) s.ignored.hush();
    var a = (args_mod.parseEvalArgs(&args, p.rest) catch |e| return args.report(e)).eval;
    a.no_tracing_cache = true;
    a.flake_whole = true;
    // nix-eval-jobs takes the argument as a file unless --flake says otherwise.
    if (a.input) |in| switch (in) {
        .flake, .file => |f| a.input = if (j.flake) .{ .flake = f } else .{ .file = f },
        .expr => {},
    };
    if (a.input == null) return fail(s, error.Usage, "no expression specified");
    // nix-eval-jobs.cc: `--impure` wins, then `--flake` makes it pure, then
    // `--pure-eval`, `--option pure-eval` and nix.conf decide.
    if (j.impure) {
        a.pure = false;
    } else if (j.flake) {
        a.pure = true;
    } else if (a.pure == null) {
        if (s.nix_conf) |*conf| {
            var d: Diag = .init(arena);
            a.pure = conf.boolean("pure-eval", &d) catch null;
        }
    }
    var d: Diag = .init(s.gpa);
    defer d.deinit();
    const transport = checkJobsArgs(arena, &j, c.init.environ_map, &d) catch |e| return failDiag(s, e, &d);
    var x: Cmd = .{
        .c = c,
        .s = s,
        .arena = arena,
        .gpa = s.gpa,
        .io = s.io,
        .a = a,
        .j = j,
        .transport = transport,
        .t0 = now(s.io),
        .walk = .init(s.gpa, s.io),
        .cwd = std.process.currentPathAlloc(s.io, arena) catch "/",
    };
    defer x.walk.deinit();
    // the process model is this command's own: the collector evaluates
    // nothing itself, and a worker is one evaluator thread with no cache
    if (!j.worker and j.max_memory > 0) return jobsCollector(&x, argv);
    if (j.worker) x.a.workers = 1;
    const run: Run = .{ .s = s, .init = c.init, .args = &x.a, .keep_aterm = !j.opts.no_instantiate, .keep_site = j.opts.provenance };
    if (j.worker) return run.go(&x, jobsWorker);
    return run.go(&x, jobsSingle);
}

fn now(io: Io) u64 {
    return @intCast(Io.Clock.awake.now(io).toNanoseconds());
}

/// worker.cc:initializeRootValue: the root, auto-called with the
/// `--arg`s, then `--select`ed; the walk configured on the way.
fn jobsRoot(x: *Cmd, ev: *Evaluator) Evaluator.Error!Value {
    const auto = try api.autoArgs(ev, x.arena, x.a.args);
    const apply: ?Value = if (x.j.apply) |e| try import_.evalString(ev, e) else null;
    try x.walk.configure(ev, x.j.opts, auto, apply);
    var a = x.a;
    a.args = &.{};
    const root = try ev.autoCall(try api.evaluate(ev, x.arena, &a, x.cwd), auto);
    const select = x.j.select orelse return root;
    const f = try import_.evalString(ev, select);
    const v = try ev.apply(f, &.{root}, .none);
    _ = try ev.forceAttrs(v, .none, "'--select' must evaluate to an attrset (the traversal root)");
    return v;
}

/// The emitter behind a lock, writing the session's stdout, so
/// the workers' lines do not interleave.
const Locked = struct {
    lock: Io.Mutex = .init,
    io: Io,
    em: Emitter = undefined,
    out: OutWriter,
    buf: [64 << 10]u8 = undefined,

    /// In place: the emitter points at `out`.
    fn init(l: *Locked, x: *const Cmd) void {
        l.* = .{ .io = x.io, .out = .{ .out = &x.s.out, .interface = .{ .vtable = &.{ .drain = OutWriter.drain }, .buffer = &.{} } } };
        l.out.interface.buffer = &l.buf;
        l.em = .init(x.gpa, &l.out.interface, x.j.opts.constituents);
    }

    fn emit(l: *Locked, line: Line) void {
        l.lock.lockUncancelable(l.io);
        defer l.lock.unlock(l.io);
        l.em.emit(line) catch {};
    }

    fn sink(l: *Locked) jobs.Sink {
        return .{ .ctx = l, .f = struct {
            fn f(ctx: ?*anyopaque, line: Line) void {
                const self: *Locked = @ptrCast(@alignCast(ctx.?));
                self.emit(line);
            }
        }.f };
    }
};

/// A buffered writer into the session's stdout, which a host may redirect.
const OutWriter = struct {
    out: *Stdout,
    interface: Writer,

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const self: *OutWriter = @fieldParentPtr("interface", w);
        self.out.writeAll(w.buffered()) catch return error.WriteFailed;
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |b| {
            self.out.writeAll(b) catch return error.WriteFailed;
            n += b.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            self.out.writeAll(last) catch return error.WriteFailed;
            n += last.len;
        }
        return n;
    }
};

fn secs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
}

fn jobsSummary(x: *const Cmd, stats: jobs.Stats, inst: ?instantiate.Stats, spawned: usize) !void {
    // the real nix-eval-jobs says nothing, so classic mode says nothing
    if (x.j.quiet or x.s.log.isClassic()) return;
    var aw: Writer.Allocating = .init(x.arena);
    const w = &aw.writer;
    try w.print("eval-jobs: {d} jobs, {d} errors, {d:.3}s, ", .{ stats.jobs, stats.errors, secs(now(x.io) - x.t0) });
    if (x.j.max_memory > 0) {
        try w.print("{d} worker processes spawned", .{spawned});
    } else try w.print("peak RSS {d} MB", .{collector.peakRssMb(x.io)});
    if (stats.jobs + stats.errors == 0 and x.j.opts.chunks == 1) {
        try w.writeAll("\nhint: the root has no derivations");
        if (!x.j.opts.force_recurse)
            try w.writeAll("; a nested set counts with recurseForDerivations = true or --force-recurse");
    }
    if (inst) |i| try w.print("\ninstantiate: {d} batches, {d} paths queried, {d} added ({d} MB), {d} roots, {d:.3}s", .{
        i.upload.batches, i.upload.queried, i.upload.added, i.upload.bytes >> 20, i.roots, secs(i.upload.time),
    });
    x.s.log.textLine(aw.written());
}

/// The tail every role shares: the emitter's `finish` when a connection is
/// there for it, the summary line, and the exit code.
fn jobsFinish(x: *const Cmd, l: *Locked, conn: ?*Connection, inst: ?instantiate.Stats, spawned: usize) u8 {
    l.lock.lockUncancelable(l.io);
    defer l.lock.unlock(l.io);
    if (conn) |cn| {
        var d: Diag = .init(x.gpa);
        defer d.deinit();
        l.em.finish(x.io, cn, &x.s.log, x.j.gc_roots_dir, &d) catch |e| return failDiag(x.s, e, &d);
    }
    // `| head`: the reader is gone, so the summary has nowhere to go either
    if (l.em.closed) return 0;
    jobsSummary(x, l.em.stats, inst, spawned) catch {};
    return if (l.em.fatal) 1 else 0;
}

/// What the instantiating thread does with a batch: cache status, then out.
const BatchOut = struct {
    l: *Locked,
    gpa: Allocator,
    resolver: ?*Resolver,

    fn f(ctx: ?*anyopaque, lines: []Line, d: *Diag) jobs.Error!void {
        const b: *BatchOut = @ptrCast(@alignCast(ctx.?));
        var done: usize = 0;
        defer for (lines[done..]) |*l| l.deinit(b.gpa);
        if (b.resolver) |r| try r.resolve(lines, d);
        b.l.lock.lockUncancelable(b.l.io);
        defer b.l.lock.unlock(b.l.io);
        for (lines) |l| {
            done += 1;
            try b.l.em.emit(l);
        }
    }
};

/// One process: the walk on the main fiber, instantiation and cache
/// status on a thread beside it, constituents at the end.
fn jobsSingle(x: *Cmd, ev: *Evaluator) !u8 {
    const root = try jobsRoot(x, ev);
    var l: Locked = undefined;
    l.init(x);
    defer l.em.deinit();
    if (x.j.opts.no_instantiate) {
        try x.walk.run(ev, root, l.sink());
        if (x.s.settings.stats >= 1) api.printStats(ev, x.c.init.environ_map);
        return jobsFinish(x, &l, null, null, 0);
    }
    var d: Diag = .init(x.gpa);
    defer d.deinit();
    const store = Store.open(x.cx(), &x.transport, x.j.gc_roots_dir, ev, x.nix(), &d) catch |e| return failDiag(x.s, e, &d);
    var resolver: ?Resolver = null;
    defer if (resolver) |*r| r.deinit();
    if (x.j.check_cache_status) resolver = Resolver.open(x.gpa, x.io, &x.transport, x.env(), &d) catch |e| {
        store.close();
        return failDiag(x.s, e, &d);
    };
    var bo: BatchOut = .{ .l = &l, .gpa = x.gpa, .resolver = if (resolver) |*r| r else null };
    const inst = Instantiator.start(x.gpa, x.io, store, .{ .ctx = &bo, .f = BatchOut.f }, &d) catch |e| {
        store.close();
        return failDiag(x.s, e, &d);
    };
    const walked = x.walk.run(ev, root, .{ .ctx = inst, .f = struct {
        fn f(ctx: ?*anyopaque, line: Line) void {
            const i: *Instantiator = @ptrCast(@alignCast(ctx.?));
            i.push(line);
        }
    }.f });
    const st = inst.finish(&d) catch |e| return failDiag(x.s, e, &d);
    defer st.close();
    try walked;
    return jobsFinish(x, &l, st.connection(), st.stats, 0);
}

/// Where a worker's instantiated lines go: its stdout, to the collector.
const WorkerOut = struct {
    out: *collector.Out,
    gpa: Allocator,

    fn f(ctx: ?*anyopaque, lines: []Line, _: *Diag) jobs.Error!void {
        const o: *WorkerOut = @ptrCast(@alignCast(ctx.?));
        var done: usize = 0;
        defer for (lines[done..]) |*l| l.deinit(o.gpa);
        for (lines) |*l| {
            const bytes = try l.renderAlloc(o.gpa);
            defer o.gpa.free(bytes);
            o.out.write(bytes);
            l.deinit(o.gpa);
            done += 1;
        }
    }
};

/// A worker process under `--max-memory-size`: the root once, then `do`
/// requests from the collector until `exit` or the limit.
fn jobsWorker(x: *Cmd, ev: *Evaluator) !u8 {
    var out: collector.Out = .{ .io = x.io };
    const root = jobsRoot(x, ev) catch |e| switch (e) {
        error.EvalFailed => {
            var arena: std.heap.ArenaAllocator = .init(x.gpa);
            defer arena.deinit();
            return workerFail(x, &out, try jobs.errorReport(ev, arena.allocator()));
        },
        else => return e,
    };
    if (x.s.ignored.nixConfigWasSeen()) out.write(collector.msg_nix_config);
    var d: Diag = .init(x.gpa);
    defer d.deinit();
    var wo: WorkerOut = .{ .out = &out, .gpa = x.gpa };
    var inst: ?*Instantiator = null;
    if (!x.j.opts.no_instantiate) {
        const store = Store.open(x.cx(), &x.transport, x.j.gc_roots_dir, ev, x.nix(), &d) catch |e|
            return workerFail(x, &out, .{ .code = errors.code(e), .raw = d.message() });
        inst = Instantiator.start(x.gpa, x.io, store, .{ .ctx = &wo, .f = WorkerOut.f }, &d) catch |e| {
            store.close();
            return workerFail(x, &out, .{ .code = errors.code(e), .raw = d.message() });
        };
    }
    collector.runWorker(&x.walk, ev, root, inst, x.j.max_memory, &out, &d) catch |e|
        return workerFail(x, &out, .{ .code = errors.code(e), .raw = d.message() });
    return 0;
}

/// The error a worker leaves with: as a line its collector reports, and on
/// stderr. The exit code.
fn workerFail(x: *const Cmd, out: *collector.Out, r: Report) u8 {
    var arena: std.heap.ArenaAllocator = .init(x.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (r.text(a)) |text| {
        if (jobs.line.jsonStr(a, text)) |js| {
            if (std.fmt.allocPrint(a, "{{\"error\":{s}}}", .{js})) |l| out.write(l) else |_| {}
        } else |_| {}
    } else |_| {}
    return r.emit(&x.s.log);
}

/// `--check-cache-status` beside the collectors: what queued since the
/// last batch is resolved in one go, then emitted.
const CacheThread = struct {
    gpa: Allocator,
    io: Io,
    l: *Locked,
    resolver: Resolver,
    lock: Io.Mutex = .init,
    cond: Io.Condition = .init,
    queue: std.ArrayList(Line) = .empty,
    closed: bool = false,
    failed: bool = false,
    result: jobs.Error!void = {},
    diag: Diag,

    fn push(t: *CacheThread, line: Line) void {
        var x = line;
        t.lock.lockUncancelable(t.io);
        defer t.lock.unlock(t.io);
        if (t.failed) return x.deinit(t.gpa);
        t.queue.append(t.gpa, x) catch return x.deinit(t.gpa);
        t.cond.signal(t.io);
    }

    fn close(t: *CacheThread) void {
        t.lock.lockUncancelable(t.io);
        defer t.lock.unlock(t.io);
        t.closed = true;
        t.cond.signal(t.io);
    }

    fn run(t: *CacheThread) void {
        t.result = t.loop();
        t.lock.lockUncancelable(t.io);
        defer t.lock.unlock(t.io);
        if (t.result) |_| {} else |_| t.failed = true;
        for (t.queue.items) |*l| l.deinit(t.gpa);
        t.queue.clearRetainingCapacity();
    }

    fn loop(t: *CacheThread) jobs.Error!void {
        while (true) {
            var batch = blk: {
                t.lock.lockUncancelable(t.io);
                defer t.lock.unlock(t.io);
                while (t.queue.items.len == 0) {
                    if (t.closed) return;
                    t.cond.waitUncancelable(t.io, &t.lock);
                }
                const b = t.queue;
                t.queue = .empty;
                break :blk b;
            };
            defer batch.deinit(t.gpa);
            var done: usize = 0;
            defer for (batch.items[done..]) |*l| l.deinit(t.gpa);
            try t.resolver.resolve(batch.items, &t.diag);
            t.l.lock.lockUncancelable(t.l.io);
            defer t.l.lock.unlock(t.l.io);
            for (batch.items) |l| {
                done += 1;
                try t.l.em.emit(l);
            }
        }
    }
};

/// The main process under `--max-memory-size`: collector threads drive
/// the worker processes; cache status and constituents run here.
fn jobsCollector(x: *Cmd, argv: []const []const u8) u8 {
    const s = x.s;
    var d: Diag = .init(x.gpa);
    defer d.deinit();
    var l: Locked = undefined;
    l.init(x);
    defer l.em.deinit();

    var cache: ?*CacheThread = null;
    var cache_thread: ?std.Thread = null;
    defer if (cache) |t| {
        t.resolver.deinit();
        t.queue.deinit(t.gpa);
        t.diag.deinit();
        x.gpa.destroy(t);
    };
    if (x.j.check_cache_status) {
        const resolver = Resolver.open(x.gpa, x.io, &x.transport, x.env(), &d) catch |e| return failDiag(s, e, &d);
        const t = x.gpa.create(CacheThread) catch return fail(s, error.Io, "out of memory");
        t.* = .{ .gpa = x.gpa, .io = x.io, .l = &l, .resolver = resolver, .diag = .init(x.gpa) };
        cache = t;
        cache_thread = std.Thread.spawn(.{ .stack_size = 64 << 20 }, CacheThread.run, .{t}) catch |e|
            return fail(s, error.Io, std.fmt.allocPrint(x.arena, "cannot start the cache-status thread: {s}", .{remote.ioText(e)}) catch "out of memory");
    }
    const sink: jobs.Sink = if (cache) |t| .{ .ctx = t, .f = struct {
        fn f(ctx: ?*anyopaque, line: Line) void {
            const ct: *CacheThread = @ptrCast(@alignCast(ctx.?));
            ct.push(line);
        }
    }.f } else l.sink();

    const exe = std.process.executablePathAlloc(x.io, x.arena) catch |e|
        return fail(s, error.Io, std.fmt.allocPrint(x.arena, "current_exe: {s}", .{remote.ioText(e)}) catch "out of memory");
    const wargv = workerArgv(s, x.arena, exe, argv, &x.j) catch return fail(s, error.Io, "out of memory");
    var env = x.env().clone(x.arena) catch return fail(s, error.Io, "out of memory");
    env.put("IETS_SESSION_ID", s.log.sessionId()) catch return fail(s, error.Io, "out of memory");
    const workers: usize = if (x.a.workers > 0) x.a.workers else if (s.settings.workers) |w| @intCast(w) else @min(4, std.Thread.getCpuCount() catch 1);

    var co: collector.Collector = .{ .gpa = x.gpa, .io = x.io, .s = s, .argv = wargv, .env = &env, .sink = sink };
    defer co.deinit();
    var r = co.run(workers, &d);
    if (cache) |t| {
        t.close();
        cache_thread.?.join();
        if (r) |_| {
            r = t.result;
            if (t.result) |_| {} else |_| d.msg = d.gpa.dupe(u8, t.diag.message()) catch null;
        } else |_| {}
    }
    r catch |e| return failDiag(s, e, &d);
    var conn: ?*Connection = null;
    defer if (conn) |cn| cn.close();
    if (x.j.opts.constituents)
        conn = Connection.open(x.gpa, x.io, &x.transport, x.env(), .of(&s.log), .ignore, &d) catch |e| return failDiag(s, e, &d);
    return jobsFinish(x, &l, conn, null, co.spawned.load(.monotonic));
}

const testing = std.testing;

test "a worker gets the --argstr its collector read from stdin" {
    const s = try Session.create(testing.allocator, testing.io, .{});
    defer s.destroy();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var j: JobsArgs = .{};
    try j.stdin_args.append(arena.allocator(), .{ "system", "x86_64-linux\n" });
    const got = try workerArgv(s, arena.allocator(), "/bin/iets", &.{ "--meta", "--arg-from-stdin", "system", "ci.nix" }, &j);
    const want = [_][]const u8{ "/bin/iets", "eval-jobs", "--worker", "--meta", "--argstr", "system", "x86_64-linux\n", "ci.nix" };
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "incompatible flags" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d: Diag = .init(arena.allocator());
    var j: JobsArgs = .{};
    j.opts.no_instantiate = true;
    j.opts.constituents = true;
    j.check_cache_status = true;
    try testing.expectError(error.Usage, checkJobsArgs(arena.allocator(), &j, null, &d));
    try testing.expectEqualStrings("--no-instantiate is incompatible with: --check-cache-status, --constituents. These features require instantiated derivations.", d.message());
    j = .{};
    j.opts.chunks = 2;
    j.opts.chunk = 2;
    try testing.expectError(error.Usage, checkJobsArgs(arena.allocator(), &j, null, &d));
    try testing.expectEqualStrings("--chunk must be below --chunks", d.message());
}
