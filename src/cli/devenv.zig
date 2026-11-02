//! `iets print-dev-env`: the shell environment of a flake's devShell: the
//! flags, the GC roots, the cache logic and the output. Evaluating the
//! installable and building the `-env` derivation are `devenv_hooks.zig`'s.

const std = @import("std");
const render = @import("render.zig");
const text_ = @import("../syntax/text.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const linux = std.os.linux;
const Diag = @import("../diag.zig").Diag;
const Session = @import("../session.zig").Session;
const Report = @import("../log.zig").Report;
const errors = @import("../errors.zig");
const config = @import("../config.zig");
const cachefs = @import("../cachefs.zig");
const sys = @import("../sys.zig");
const devenv = @import("../devenv.zig");
const BuildEnvironment = devenv.BuildEnvironment;
const CachedResult = devenv.CachedResult;
const provenance = @import("../provenance.zig");
const Provenance = provenance.Provenance;
const remote = @import("../remote.zig");
const worker = remote.worker;
const Transport = worker.Transport;
const Connection = worker.Connection;
const event = @import("../remote/event.zig");
const Event = event.Event;
const Sink = event.Sink;
const drv_mod = @import("../store/drv.zig");
const Derivation = drv_mod.Derivation;
const hash_mod = @import("../store/hash.zig");
const path_mod = @import("../store/path.zig");
const StorePath = path_mod.StorePath;
const nar = @import("../store/nar.zig");
const canonPath = @import("../eval/Evaluator.zig").canonPath;
const api = @import("../api.zig");
const cli = @import("../cli.zig");
const args_mod = @import("args.zig");

pub const Error = remote.Error || devenv.Error || error{ Cache, Eval };

/// What this command needs of the run around it: the session, plus the
/// environment and the activity log a daemon connection takes.
pub const Ctx = struct {
    s: *Session,
    /// For `Connection.open`: `ssh-ng://` reads `SSH_*` and the socket's
    /// default reads `NIX_DAEMON_SOCKET_PATH`.
    env_map: ?*const std.process.Environ.Map,
    /// The session's log for the daemon's activities (`remote.Log.of`).
    log: remote.Log = .none,

    fn open(c: *const Ctx, transport: *const Transport, d: *Diag) Error!*Connection {
        return Connection.open(c.s.gpa, c.s.io, transport, c.env_map, c.log, .ignore, d);
    }

    fn errln(c: *const Ctx, comptime fmt: []const u8, args: anytype) void {
        var buf: [4096]u8 = undefined;
        c.s.log.errln(std.fmt.bufPrint(&buf, fmt, args) catch blk: {
            @memcpy(buf[buf.len - 3 ..], "...");
            break :blk &buf;
        });
    }

    /// `e`, with the message on `d`, as its report; the exit code.
    fn report(c: *const Ctx, d: *const Diag, e: anyerror) u8 {
        const r = errors.report(e, d);
        return r.emit(&c.s.log);
    }
};

/// The steps that evaluate or build, on the evaluator, installable
/// resolution and the build dispatcher. Every string a step returns lives
/// in the `arena` it was given.
pub const Hooks = @import("devenv_hooks.zig").Impl;

/// Where the root of a shell's environment goes. A caller that named a path
/// owns it: the path is a contract and a failure is the command's. Where
/// nothing was named, `nix develop` takes a link in iets's roots store, and
/// that one is best effort — see `keepRoot`.
pub const GcRoot = union(enum) {
    none,
    /// `print-dev-env --gc-root PATH`, absolute.
    given: []const u8,
    /// A link in iets's roots store, from `shellRoot`.
    store: []const u8,

    /// The path the caller named, which also holds the `-attrs` directory the
    /// rc script points at. A link in the roots store is not one.
    pub fn given_(r: GcRoot) ?[]const u8 {
        return switch (r) {
            .given => |p| p,
            else => null,
        };
    }

    /// Points this run's root at `out_path`.
    pub fn register(r: GcRoot, c: *const Ctx, transport: *const Transport, out_path: []const u8, conn: ?*Connection, d: *Diag) Error!void {
        switch (r) {
            .none => {},
            .given => |p| try ensureGcRoot(c, transport, p, out_path, conn, d),
            .store => |p| keepRoot(c, transport, p, out_path, conn),
        }
    }
};

/// The link in the roots store that `parts` name (`cachefs.rootLink`), in
/// `arena`; null when no cache root is known.
pub fn rootLink(arena: Allocator, env_map: *const std.process.Environ.Map, parts: []const []const u8) !?[]const u8 {
    const root = try cachefs.root(arena, env_map, null) orelse return null;
    return try cachefs.rootLink(arena, root, parts);
}

/// The root `nix develop` keeps for the flake installable whose directory is
/// `flake_dir` and whose attribute path is `attr` (`api::flake_ref`). It has no
/// flag for one, so it keeps one of its own: the `-env` output references the
/// whole shell, so a single link holds it, keyed on the flake directory and the
/// attribute path — two flakes on one machine keep two roots, two shells of one
/// flake keep two, and one shell replaces its own in place
/// (`docs/explanation/caching.md`). `NIX_GCROOT` is not this root: that one
/// holds the closure only while the shell runs, which is what nix does with it.
/// A reference that does not resolve has none.
pub fn flakeShellRoot(c: *const Ctx, arena: Allocator, transport: *const Transport, f: []const u8) !GcRoot {
    const cwd = std.process.currentPathAlloc(c.s.io, arena) catch return .none;
    var d: Diag = .init(arena);
    const fr = @import("../api/flake.zig").flakeRef(arena, c.s.io, f, cwd, &d) catch return .none;
    const a = try std.mem.join(arena, ".", fr.attr);
    const p = try shellRoot(c, arena, transport, &.{ "develop", fr.dir, a }) orelse return .none;
    return .{ .store = p };
}

/// The link iets keeps for a shell of its own accord, named by `parts` as
/// `nix fmt`'s is (`classic/fmt.zig`). Null when the `shell-gc-root`
/// setting is off, when the daemon is not local — only a local daemon takes a
/// root — or when no cache root is known.
pub fn shellRoot(c: *const Ctx, arena: Allocator, transport: *const Transport, parts: []const []const u8) !?[]const u8 {
    if (!shellRoots(c, transport)) return null;
    return rootLink(arena, c.env_map orelse return null, parts);
}

/// Whether a shell keeps a root of its own: the `shell-gc-root` setting
/// (`docs/reference/settings.md`), and a local daemon, the only kind that takes
/// one. Ask before doing the work a root needs.
pub fn shellRoots(c: *const Ctx, transport: *const Transport) bool {
    return ownRoot(c.s.settings.shell_gc_root, transport);
}

/// The same question for a build's outputs, under `build-gc-root`.
fn buildRoots(c: *const Ctx, transport: *const Transport) bool {
    return ownRoot(c.s.settings.build_gc_root, transport);
}

/// `on` is the setting that allows the root; only a local daemon takes one.
fn ownRoot(on: bool, transport: *const Transport) bool {
    return on and transport.* == .unix;
}

/// Keeps the outputs a build printed alive under roots of iets's own: one
/// link in the roots store per output, named by `key` — where the command ran
/// and what it was asked to build — and by the name that tells two outputs of
/// one run apart, so a second run of the same command replaces its own roots in
/// place. A caller that named a path of its own does not come here: one root
/// per thing (`docs/explanation/caching.md`).
pub fn keepOutputs(c: *const Ctx, transport: *const Transport, key: []const []const u8, outputs: []const [2][]const u8) void {
    if (outputs.len == 0 or !buildRoots(c, transport)) return;
    const env_map = c.env_map orelse return;
    var arena: std.heap.ArenaAllocator = .init(c.s.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .init(a);
    const conn: ?*Connection = c.open(transport, &d) catch null;
    defer if (conn) |cn| cn.close();
    const parts = a.alloc([]const u8, key.len + 1) catch return;
    @memcpy(parts[0..key.len], key);
    for (outputs) |o| {
        parts[key.len] = o[0];
        const link = (rootLink(a, env_map, parts) catch return) orelse return;
        keepRoot(c, transport, link, o[1], conn);
    }
}

/// Links `out_path` at `link` in the roots store, registers the link with the
/// daemon and marks it used, so the TTL sweep keeps the roots of the shells
/// somebody still enters. Best effort and silent: classic mode prints
/// what nix prints, byte for byte, so a root a daemon will not take costs the
/// root and nothing else.
pub fn keepRoot(c: *const Ctx, transport: *const Transport, link: []const u8, out_path: []const u8, conn: ?*Connection) void {
    const io = c.s.io;
    if (std.fs.path.dirname(link)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch return;
    var d: Diag = .init(c.s.gpa);
    defer d.deinit();
    ensureGcRoot(c, transport, link, out_path, conn, &d) catch return;
    touchLink(link);
}

/// Both stamps of the link itself to now, so the TTL sweep keeps it.
fn touchLink(link: []const u8) void {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (link.len >= buf.len) return;
    @memcpy(buf[0..link.len], link);
    buf[link.len] = 0;
    _ = linux.utimensat(linux.AT.FDCWD, buf[0..link.len :0], null, linux.AT.SYMLINK_NOFOLLOW);
}

fn inStore(p: []const u8) bool {
    const sd = path_mod.store_dir;
    return std.mem.startsWith(u8, p, sd) and (p.len == sd.len or p[sd.len] == '/');
}

/// indirect-root-store.cc:addPermRoot: a symlink at `root` to `out_path`, then
/// `AddIndirectRoot`. Nothing happens when the link already points there.
pub fn ensureGcRoot(c: *const Ctx, transport: *const Transport, root: []const u8, out_path: []const u8, conn: ?*Connection, d: *Diag) Error!void {
    const io = c.s.io;
    const cwd = Io.Dir.cwd();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const target: ?[]const u8 = if (cwd.readLink(io, root, &buf)) |n| buf[0..n] else |_| null;
    if (target) |t| if (std.mem.eql(u8, t, out_path)) return;
    if (inStore(root))
        return d.fail(error.Usage, "creating a garbage collector root ({s}) in the Nix store is forbidden", .{root});
    if (cwd.statFile(io, root, .{ .follow_symlinks = false })) |st| {
        if (st.kind != .sym_link or !inStore(target orelse ""))
            return d.fail(error.Usage, "cannot create symlink {s}; already exists", .{root});
    } else |_| {}
    worker.replaceSymlink(c.s.gpa, io, out_path, root) catch |e|
        return remote.failIo(d, e, "cannot create {s}", .{root});
    if (!std.unicode.utf8ValidateSlice(root)) return d.fail(error.Usage, "gc root path is not UTF-8", .{});
    if (conn) |cn| return cn.addIndirectRoot(root, .ignore, d);
    const opened = try c.open(transport, d);
    defer opened.close();
    try opened.addIndirectRoot(root, .ignore, d);
}

/// Build events on the daemon connection: log lines are printed live with `--timings`,
/// else kept and printed only when the build fails.
pub const EventSink = struct {
    c: *const Ctx,
    live: bool,
    arena: Allocator,
    log: std.ArrayList([]const u8) = .empty,
    failed: ?[]const u8 = null,
    prov: *const Provenance,

    pub fn sink(s: *EventSink) Sink {
        return .of(EventSink, s);
    }

    pub fn onEvent(s: *EventSink, e: Event) void {
        s.handle(e) catch {};
    }

    fn handle(s: *EventSink, e: Event) !void {
        switch (e) {
            .log => |l| {
                var buf: Writer.Allocating = .init(s.arena);
                try s.prov.rewrite(&buf.writer, try text_.lossyAlloc(s.arena, l.line));
                const line = buf.written();
                if (s.live) s.c.errln("iets: {s}", .{line}) else try s.log.append(s.arena, line);
            },
            .started => |st| if (s.live) {
                if (try s.prov.started(s.arena, st.drv_path)) |l|
                    s.c.errln("iets: {s}", .{l})
                else
                    s.c.errln("iets: building {s}", .{st.drv_path});
            },
            .failed => |f| {
                s.failed = if (try s.prov.failed(s.arena, f.drv_path, f.reason)) |l|
                    std.mem.trimStart(u8, l, "error: ")
                else blk: {
                    var buf: Writer.Allocating = .init(s.arena);
                    try buf.writer.print("build of {s} failed: ", .{f.drv_path});
                    try s.prov.rewrite(&buf.writer, f.reason);
                    break :blk buf.written();
                };
            },
            else => {},
        }
    }

    fn dump(s: *const EventSink) void {
        for (s.log.items) |l| s.c.errln("iets: {s}", .{l});
    }
};

/// How many bytes of `b`, which starts a broken sequence of `n` bytes (0 for a
/// byte that starts none), are a prefix some valid sequence has.
fn brokenLen(b: []const u8, n: usize) usize {
    if (n < 2 or b.len < 2) return 1;
    const lo: u8, const hi: u8 = switch (b[0]) {
        0xe0 => .{ 0xa0, 0xbf },
        0xed => .{ 0x80, 0x9f },
        0xf0 => .{ 0x90, 0xbf },
        0xf4 => .{ 0x80, 0x8f },
        else => .{ 0x80, 0xbf },
    };
    if (b[1] < lo or b[1] > hi) return 1;
    var k: usize = 2;
    while (k < n and k < b.len and b[k] & 0xc0 == 0x80) k += 1;
    return k;
}

/// `iets print-dev-env`'s command line, parsed.
pub const Request = struct {
    builder: ?[]const u8 = null,
    gc_root: ?[]const u8 = null,
    entry_to: ?[]const u8 = null,
    /// The flake reference; `.` when none was given.
    flake: ?[]const u8 = null,
    /// The evaluation flags (`parse_eval_args`), the input not yet set.
    eval: api.EvalArgs = .{},
};

/// The command's own flags first, over all of `argv`:
/// a flag of its own or one of the evaluation flags in `pass` takes the next
/// word, every other word with a dash goes to `parse_eval_args`, and the
/// rest is the flake reference.
pub fn parse(a: *args_mod.Args) args_mod.Error!Request {
    var r: Request = .{};
    var rest: std.ArrayList([]const u8) = .empty;
    const pass = [_][]const u8{ "--workers", "--cache-dir", "-I", "--include", "--log-format" };
    while (a.i < a.argv.len) : (a.i += 1) {
        const x = a.argv[a.i];
        const eql = std.mem.eql;
        if (eql(u8, x, "--builder")) {
            r.builder = try a.next(x);
        } else if (eql(u8, x, "--gc-root")) {
            r.gc_root = try a.next(x);
        } else if (eql(u8, x, "--entry-to")) {
            r.entry_to = try a.next(x);
        } else if (for (pass) |p| {
            if (eql(u8, x, p)) break true;
        } else false) {
            try rest.appendSlice(a.arena, &.{ x, try a.next(x) });
        } else if (std.mem.startsWith(u8, x, "-")) {
            try rest.append(a.arena, x);
        } else {
            if (r.flake) |old| return a.fail("one FLAKEREF only, got '{s}' and '{s}'", .{ old, x });
            r.flake = x;
        }
    }
    r.eval = (try args_mod.parseEvalArgs(a, rest.items)).eval;
    return r;
}

/// What the daemon flow needs besides the evaluation.
pub const DevEnvArgs = struct {
    transport: Transport,
    /// `nix develop`'s `-j`, `--cores` and the rest; the defaults natively.
    options: worker.Options,
    gc_root: GcRoot,
};

/// `iets print-dev-env`: the bash `nix print-dev-env` prints for a flake's shell, from the
/// in-memory shell derivation through a Nix daemon. See docs/reference/commands.md.
/// The exit code is returned.
pub fn printDevEnv(c: *const Ctx, hooks: *Hooks, req: *const Request) u8 {
    const s = c.s;
    var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var d: Diag = .init(s.gpa);
    defer d.deinit();
    return printDevEnvIn(c, hooks, arena, req, &d) catch |e| c.report(&d, e);
}

fn printDevEnvIn(c: *const Ctx, hooks: *Hooks, arena: Allocator, req: *const Request, d: *Diag) Error!u8 {
    const s = c.s;
    const flake = req.flake orelse ".";
    hooks.begin(req.eval, flake, "print-dev-env");
    // the environment runs here, so its inputs belong in the local store:
    // the `builder` setting does not apply
    const url = req.builder orelse blk: {
        if (s.nix_conf) |*conf| break :blk try arena.dupe(u8, conf.store());
        var scratch: Diag = .init(arena);
        var conf = config.Config.read(arena, s.io, s.env, &.{}, &scratch) catch config.Config.empty(arena, s.io, s.env);
        break :blk conf.store();
    };
    const transport = Transport.parse(arena, url, c.env_map) orelse
        return d.fail(error.Usage, "print-dev-env needs a Nix daemon: --builder daemon, unix:///path or ssh-ng://host", .{});
    const gc_root: GcRoot = if (req.gc_root) |r| .{ .given = try absPath(arena, s, r) } else .none;
    if (transport == .grpc)
        return d.fail(error.Usage, "print-dev-env needs a Nix daemon; grpc:// only builds", .{});
    if (gc_root == .given and transport != .unix)
        return d.fail(error.Usage, "--gc-root needs a local daemon (daemon or unix://)", .{});
    const args: DevEnvArgs = .{ .transport = transport, .options = .default(), .gc_root = gc_root };
    const timings = req.eval.timings;

    const t0 = sys.monotonicNs();
    // the caller asked where this run's entry lives, so it can hand that to
    // `iets cache paths` instead of deriving the key a second time
    if (req.entry_to) |f| {
        const path = hooks.entryPath(arena) orelse
            return d.fail(error.Cache, "--entry-to needs the tracing cache, and this run has none", .{});
        Io.Dir.cwd().writeFile(s.io, .{ .sub_path = f, .data = path }) catch |e|
            return remote.failIo(d, e, "--entry-to '{s}'", .{f});
    }
    if (hooks.cachedResult(arena)) |bytes| if (try CachedResult.decode(arena, bytes)) |hit| {
        if (try devEnvHit(c, &args, &hit, d)) {
            hooks.replayWarnings();
            try render.write(s, hit.bytes, d);
            if (timings) c.errln("total: {d:.3}s", .{secondsSince(t0)});
            return 0;
        }
        if (timings) c.errln("cache: env output '{s}' is gone, rebuilding", .{hit.out_path});
    };
    // parallel: eval and the daemon flow run as the main fiber
    var job: FullJob = .{ .c = c, .hooks = hooks, .arena = arena, .timings = timings, .json = req.eval.json, .args = &args, .flake = flake, .t0 = t0 };
    return hooks.run(FullJob.go, &job);
}

fn absPath(arena: Allocator, s: *Session, p: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, p, "/")) return p;
    const cwd = std.process.currentPathAlloc(s.io, arena) catch "/";
    return canonPath(arena, try std.mem.concat(arena, u8, &.{ cwd, "/", p }));
}

fn secondsSince(t0: u64) f64 {
    return @as(f64, @floatFromInt(sys.monotonicNs() - t0)) / std.time.ns_per_s;
}

/// A cache hit is usable when the env output (and the files the script names) still exist;
/// the GC root is refreshed when it does not point at the output.
pub fn devEnvHit(c: *const Ctx, args: *const DevEnvArgs, hit: *const CachedResult, d: *Diag) Error!bool {
    const present = switch (args.transport) {
        .unix => sys.fs.exists(hit.out_path),
        .ssh, .grpc => blk: {
            var arena: std.heap.ArenaAllocator = .init(c.s.gpa);
            defer arena.deinit();
            const conn = try c.open(&args.transport, d);
            defer conn.close();
            const out = try StorePath.parse(hit.out_path, d);
            break :blk (try conn.queryValid(arena.allocator(), &.{out}, .ignore, d)).len > 0;
        },
    };
    if (!present) return false;
    for (hit.files) |f| if (!sys.fs.exists(f)) return false;
    try args.gc_root.register(c, &args.transport, hit.out_path, null, d);
    return true;
}

/// What the `-env` build produced: the environment `get-env.sh` dumped, the output that
/// holds it (`nix develop` makes it `NIX_GCROOT`), and the shell derivation's builder.
pub const DevEnv = struct {
    env: BuildEnvironment,
    out_path: []const u8,
    /// `<store path>/bin/bash`: the bash the shell was built with.
    builder: []const u8,
    /// When the daemon phase started (`sys.monotonicNs`), for the caller's `--timings` line.
    t1: u64,
};

/// `print-dev-env` without the printing: the build environment of the flake installable
/// `flake` names. `nix develop` (classic/develop.zig) uses this. `hooks` were
/// configured by the caller, with the cache kind `develop` when the transport is
/// local (a hit reads the environment out of the local store) and none otherwise.
/// Strings go into `arena`. A failure is reported, its exit code in `hooks.code`.
pub fn devEnv(c: *const Ctx, hooks: *Hooks, arena: Allocator, flake: []const u8, timings: bool, args: *const DevEnvArgs) error{Reported}!DevEnv {
    var d: Diag = .init(c.s.gpa);
    defer d.deinit();
    if (hooks.cachedResult(arena)) |bytes| if (rememberedEnv(arena, c.s.io, bytes)) |env| {
        hooks.replayWarnings();
        args.gc_root.register(c, &args.transport, env.out_path, null, &d) catch |e| return hooks.exit(c.report(&d, e));
        return env;
    };
    var job: DevJob = .{ .c = c, .hooks = hooks, .arena = arena, .args = args, .flake = flake, .timings = timings };
    const code = hooks.run(DevJob.go, &job);
    return job.result orelse hooks.exit(code);
}

const DevJob = struct {
    c: *const Ctx,
    hooks: *Hooks,
    arena: Allocator,
    args: *const DevEnvArgs,
    flake: []const u8,
    timings: bool,
    result: ?DevEnv = null,

    fn go(ctx: *anyopaque) u8 {
        const j: *DevJob = @ptrCast(@alignCast(ctx));
        const env = devEnvBuild(j.c, j.hooks, j.arena, j.flake, j.timings, j.args) catch return j.hooks.code;
        const text = std.fmt.allocPrint(j.arena, "{s}\n{s}", .{ env.out_path, env.builder }) catch return 1;
        j.hooks.writeResult(text);
        j.result = env;
        return 0;
    }
};

/// What a `develop` entry holds is the `-env` output and the shell's builder,
/// neither of which can hold a newline. The environment itself stays in the
/// output: an output that is gone is a miss, and the run builds it again.
pub fn rememberedEnv(arena: Allocator, io: Io, result: []const u8) ?DevEnv {
    if (!std.unicode.utf8ValidateSlice(result)) return null;
    const nl = std.mem.indexOfScalar(u8, result, '\n') orelse return null;
    const out_path = result[0..nl];
    const bytes = Io.Dir.cwd().readFileAlloc(io, out_path, arena, .unlimited) catch return null;
    var d: Diag = .init(arena);
    const env = BuildEnvironment.parse(arena, bytes, &d) catch return null;
    return .{ .env = env, .out_path = out_path, .builder = result[nl + 1 ..], .t1 = sys.monotonicNs() };
}

/// The cache-miss path: evaluate the shell, derive and build its `-env` derivation through
/// the daemon, read the environment, print it, and remember the bytes.
const FullJob = struct {
    c: *const Ctx,
    hooks: *Hooks,
    arena: Allocator,
    timings: bool,
    json: bool,
    args: *const DevEnvArgs,
    flake: []const u8,
    t0: u64,

    fn go(ctx: *anyopaque) u8 {
        const j: *FullJob = @ptrCast(@alignCast(ctx));
        const built = devEnvBuild(j.c, j.hooks, j.arena, j.flake, j.timings, j.args) catch return j.hooks.code;
        var d: Diag = .init(j.c.s.gpa);
        defer d.deinit();
        j.finish(&built, &d) catch |e| return j.c.report(&d, e);
        return 0;
    }

    fn finish(j: *FullJob, built: *const DevEnv, d: *Diag) Error!void {
        const s = j.c.s;
        const cwd = std.process.currentPathAlloc(s.io, j.arena) catch "/";
        const out = try renderOutput(j.arena, s.io, &built.env, j.json, j.args.gc_root, sys.tempDir(s.env), cwd, d);
        const entry: CachedResult = .{ .out_path = built.out_path, .files = out.files, .bytes = out.bytes };
        j.hooks.writeResult(try entry.encode(j.arena));
        if (j.timings) j.c.errln("daemon: {d:.3}s", .{secondsSince(built.t1)});
        try render.write(s, out.bytes, d);
        if (j.timings) j.c.errln("total: {d:.3}s", .{secondsSince(j.t0)});
    }
};

/// What `print-dev-env` prints for `env`, newline-terminated: the JSON with `--json`,
/// else the rc script, with the files the script names. The `.attrs` files of a
/// structured-attrs shell go beside the GC root the caller named, else into a
/// directory of this process under `tmpdir` (`sys.tempDir`).
pub fn renderOutput(
    arena: Allocator,
    io: Io,
    env: *const BuildEnvironment,
    json: bool,
    gc_root: GcRoot,
    tmpdir: []const u8,
    cwd: []const u8,
    d: *Diag,
) Error!struct { bytes: []const u8, files: []const []const u8 } {
    if (json) {
        var out: Writer.Allocating = .init(arena);
        env.writeJson(&out.writer) catch return error.OutOfMemory;
        out.writer.writeByte('\n') catch return error.OutOfMemory;
        return .{ .bytes = out.written(), .files = &.{} };
    }
    const attrs_dir = if (gc_root.given_()) |r|
        try std.fmt.allocPrint(arena, "{s}-attrs", .{r})
    else
        try std.fmt.allocPrint(arena, "{s}/iets-dev-env-{d}", .{ tmpdir, sys.pid() });
    const outputs_dir = try std.fmt.allocPrint(arena, "{s}/outputs", .{if (std.mem.eql(u8, cwd, "/")) "" else cwd});
    const rc = try devenv.makeRcScript(arena, arena, io, env, attrs_dir, outputs_dir, d);
    const bytes = try arena.realloc(rc.script, rc.script.len + 1);
    bytes[bytes.len - 1] = '\n';
    return .{ .bytes = bytes, .files = rc.files };
}

/// Evaluates the shell, derives and builds its `-env` derivation through the daemon and
/// reads the environment back. A failure is reported, its exit code in `hooks.code`.
fn devEnvBuild(c: *const Ctx, hooks: *Hooks, arena: Allocator, f: []const u8, timings: bool, args: *const DevEnvArgs) error{Reported}!DevEnv {
    var d: Diag = .init(c.s.gpa);
    defer d.deinit();
    const t0 = sys.monotonicNs();
    const hash = std.mem.indexOfScalar(u8, f, '#');
    const loc = if (hash) |i| f[0..i] else f;
    const frag = if (hash) |i| f[i + 1 ..] else "";
    const roots = hooks.evalRoots(arena, loc, frag, &d) catch |e| switch (e) {
        error.Reported => return error.Reported,
        else => |x| return hooks.exit(c.report(&d, x)),
    };
    if (roots.len != 1) {
        const e = d.fail(error.Eval, "'{s}' needs to evaluate to a single derivation, but it evaluated to {d} derivations", .{ f, roots.len });
        return hooks.exit(c.report(&d, e));
    }
    const eval_ns = sys.monotonicNs() - t0;
    return buildEnv(c, hooks, arena, roots[0], eval_ns, timings, args, &d) catch |e| hooks.exit(c.report(&d, e));
}

fn buildEnv(c: *const Ctx, hooks: *Hooks, arena: Allocator, shell_path: StorePath, eval_ns: u64, timings: bool, args: *const DevEnvArgs, d: *Diag) Error!DevEnv {
    const shell = try hooks.loadDrv(arena, shell_path, d);
    const env_drv = blk: {
        const hc = hooks.lockHashCache();
        defer hooks.releaseHashCache();
        break :blk try devenv.envDerivation(arena, &shell, hc.cache, hc.loader, d);
    };
    const text = try env_drv.unparseAlloc(arena, .{}, d);
    const env_path = try env_drv.drvPathFor(arena, text, d);
    try hooks.record(env_path, &env_drv, text, d);
    var out_paths: std.ArrayList([]const u8) = .empty;
    for (env_drv.outputs) |o| {
        const p = try env_drv.outputPath(o.name, d) orelse
            return d.fail(error.Store, "content-addressed shells are not supported", .{});
        try out_paths.append(arena, try std.fmt.allocPrint(arena, "{f}", .{&p}));
    }
    if (timings) c.errln("eval: {d} derivations, {d:.3}s\nenv drv: {f}", .{
        hooks.derivationCount(),
        @as(f64, @floatFromInt(eval_ns)) / std.time.ns_per_s,
        &env_path,
    });

    const t1 = sys.monotonicNs();
    var prov = try hooks.provenance(c.s.gpa);
    defer prov.deinit();
    var sink: EventSink = .{ .c = c, .live = timings, .arena = arena, .prov = &prov };
    const r = try hooks.realise(arena, &args.transport, &args.options, env_path, out_paths.items, sink.sink(), d);
    defer hooks.finish();
    if (r.built) {
        if (sink.failed) |why| {
            sink.dump();
            return d.fail(error.Protocol, "{s}", .{why});
        }
        if (timings) if (r.report) |rep| c.errln("{s}", .{rep});
    } else if (timings) c.errln("daemon: env output already valid, {d:.3}s", .{secondsSince(t1)});

    const got = try readEnvOutput(c, arena, &args.transport, r.conn, out_paths.items, &sink, d);
    const env = try BuildEnvironment.parse(arena, got.bytes, d);
    try args.gc_root.register(c, &args.transport, got.out_path, r.conn, d);
    // `finish` ends the evaluation the shell's strings may live in
    return .{ .env = env, .out_path = try arena.dupe(u8, got.out_path), .builder = try arena.dupe(u8, shell.builder), .t1 = t1 };
}

/// develop.cc:getDerivationEnvironment, after the build: the first output (by name) whose
/// file is not empty holds the JSON. A local daemon's output is read from disk; a remote one
/// arrives as a NAR.
pub fn readEnvOutput(
    c: *const Ctx,
    arena: Allocator,
    transport: *const Transport,
    conn: *Connection,
    out_paths: []const []const u8,
    sink: *EventSink,
    d: *Diag,
) Error!struct { out_path: []const u8, bytes: []const u8 } {
    const io = c.s.io;
    const cwd = Io.Dir.cwd();
    for (out_paths) |p| {
        const bytes = switch (transport.*) {
            .unix => cwd.readFileAlloc(io, p, arena, .unlimited) catch |e|
                return remote.failIo(d, e, "cannot read '{s}'", .{p}),
            .ssh, .grpc => blk: {
                const dir = try std.fmt.allocPrint(arena, "{s}/iets-dev-env-{d}", .{ sys.tempDir(c.s.env), sys.pid() });
                cwd.createDirPath(io, dir) catch |e| return remote.failIo(d, e, "{s}", .{dir});
                defer cwd.deleteTree(io, dir) catch {};
                const sp = try StorePath.parse(p, d);
                const dest = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, sp.baseName() });
                cwd.deleteFile(io, dest) catch {};
                const r = try conn.narReader(&sp, sink.sink(), d);
                nar.restorePath(io, r, cwd, dest, d) catch |e| return conn.narFail(e, d);
                break :blk cwd.readFileAlloc(io, dest, arena, .unlimited) catch |e|
                    return remote.failIo(d, e, "{s}", .{dest});
            },
        };
        if (bytes.len > 0) return .{ .out_path = p, .bytes = bytes };
    }
    return d.fail(error.Protocol, "get-env.sh failed to produce an environment", .{});
}

const testing = std.testing;

test "flags" {
    const s = try Session.create(testing.allocator, testing.io, .{});
    defer s.destroy();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var p: args_mod.Args = .{ .s = s, .arena = a, .cmd = "print-dev-env", .argv = &.{ "--builder", "daemon", "--json", ".#x", "--workers", "4", "--gc-root", "r" } };
    const r = try parse(&p);
    try testing.expectEqualStrings("daemon", r.builder.?);
    try testing.expectEqualStrings("r", r.gc_root.?);
    try testing.expectEqualStrings(".#x", r.flake.?);
    try testing.expect(r.entry_to == null);
    try testing.expect(r.eval.json);
    try testing.expectEqual(4, r.eval.workers);

    p = .{ .s = s, .arena = a, .cmd = "print-dev-env", .argv = &.{ "a", "b" } };
    try testing.expectError(error.Usage, parse(&p));
    try testing.expectEqualStrings("one FLAKEREF only, got 'a' and 'b'", p.msg);
    p = .{ .s = s, .arena = a, .cmd = "print-dev-env", .argv = &.{"--entry-to"} };
    try testing.expectError(error.Usage, parse(&p));
    try testing.expectEqualStrings("--entry-to needs a value", p.msg);
}

test "root links are length-prefixed sha256 of their parts" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m: std.process.Environ.Map = .init(a);
    try m.put("IETS_CACHE_DIR", "/c");
    const l = (try rootLink(a, &m, &.{ "develop", "/f", "x" })).?;
    // sha256 of 7u64 "develop" 2u64 "/f" 1u64 "x"
    var h: hash_mod.Hasher = .init(.sha256);
    h.update("\x07\x00\x00\x00\x00\x00\x00\x00develop\x02\x00\x00\x00\x00\x00\x00\x00/f\x01\x00\x00\x00\x00\x00\x00\x00x");
    const want = try std.fmt.allocPrint(a, "/c/roots/{x}", .{h.finish().bytes()});
    try testing.expectEqualStrings(want, l);
    try testing.expect(!std.mem.eql(u8, l, (try rootLink(a, &m, &.{ "develop", "/fx", "" })).?));
}

fn testCtx(s: *Session) Ctx {
    return .{ .s = s, .env_map = null };
}

test "a gc root in the store or over a file is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try Session.create(testing.allocator, testing.io, .{});
    defer s.destroy();
    const c = testCtx(s);
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const t: Transport = .{ .unix = "/nonexistent/socket" };
    try testing.expectError(error.Usage, ensureGcRoot(&c, &t, "/nix/store/x-root", "/nix/store/a-x", null, &d));
    try testing.expectEqualStrings("creating a garbage collector root (/nix/store/x-root) in the Nix store is forbidden", d.message());

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "file", .data = "" });
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const file = try std.fmt.allocPrint(a, "{s}/file", .{base});
    try testing.expectError(error.Usage, ensureGcRoot(&c, &t, file, "/nix/store/a-x", null, &d));
    try testing.expect(std.mem.endsWith(u8, d.message(), "/file; already exists"));

    // a link that already points at the output needs no daemon
    const link = try std.fmt.allocPrint(a, "{s}/link", .{base});
    try tmp.dir.symLink(testing.io, "/nix/store/a-x", "link", .{});
    try ensureGcRoot(&c, &t, link, "/nix/store/a-x", null, &d);
}

test "a hit needs the output and its files" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try Session.create(testing.allocator, testing.io, .{});
    defer s.destroy();
    const c = testCtx(s);
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "out", .data = "{}" });
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const out = try std.fmt.allocPrint(a, "{s}/out", .{base});
    const args: DevEnvArgs = .{ .transport = .{ .unix = "/nonexistent" }, .options = .{ .max_jobs = 1 }, .gc_root = .none };
    try testing.expect(try devEnvHit(&c, &args, &.{ .out_path = out, .files = &.{out}, .bytes = "" }, &d));
    try testing.expect(!try devEnvHit(&c, &args, &.{ .out_path = out, .files = &.{"/nonexistent/.attrs.sh"}, .bytes = "" }, &d));
    try testing.expect(!try devEnvHit(&c, &args, &.{ .out_path = "/nonexistent/out", .files = &.{}, .bytes = "" }, &d));
}

const sample_env =
    \\{"bashFunctions":{},"variables":{"outputs":{"type":"var","value":"out"},"out":{"type":"exported","value":"/nix/store/a-x-env"},"V":{"type":"var","value":"/nix/store/a-x-env/v"}}}
;

test "a develop entry is the output and the builder" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "out", .data = sample_env });
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const entry = try std.fmt.allocPrint(a, "{s}/out\n/nix/store/b-bash/bin/bash", .{base});
    const env = rememberedEnv(a, testing.io, entry).?;
    try testing.expectEqualStrings("/nix/store/b-bash/bin/bash", env.builder);
    try testing.expect(env.env.get("V") != null);
    try testing.expect(rememberedEnv(a, testing.io, "/nonexistent/out\nb") == null);
    try testing.expect(rememberedEnv(a, testing.io, "no newline") == null);
}

test "output: json, and the rc script with the outputs under the cwd" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const env = try BuildEnvironment.parse(a, sample_env, &d);
    const j = try renderOutput(a, testing.io, &env, true, .none, "/tmp", "/w", &d);
    try testing.expectEqualStrings(
        \\{"bashFunctions":{},"variables":{"V":{"type":"var","value":"/nix/store/a-x-env/v"},"out":{"type":"exported","value":"/nix/store/a-x-env"},"outputs":{"type":"var","value":"out"}}}
    ++ "\n", j.bytes);
    const rc = try renderOutput(a, testing.io, &env, false, .none, "/tmp", "/w", &d);
    try testing.expect(std.mem.indexOf(u8, rc.bytes, "V='/w/outputs/out/v'\n") != null);
    try testing.expect(std.mem.endsWith(u8, rc.bytes, "eval \"${shellHook:-}\"\n\n"));
    try testing.expectEqual(0, rc.files.len);
}

test "events: lines kept until a failure, the failure named" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try Session.create(testing.allocator, testing.io, .{});
    defer s.destroy();
    const c = testCtx(s);
    var prov: Provenance = .off(testing.allocator);
    defer prov.deinit();
    var es: EventSink = .{ .c = &c, .live = false, .arena = a, .prov = &prov };
    const sk = es.sink();
    sk.send(.{ .log = .{ .drv_path = "", .line = "hello \xff" } });
    sk.send(.{ .started = .{ .drv_path = "/nix/store/a-x.drv" } });
    sk.send(worker.failedEvent("/nix/store/a-x.drv", "boom"));
    try testing.expectEqual(1, es.log.items.len);
    try testing.expectEqualStrings("hello \u{fffd}", es.log.items[0]);
    try testing.expectEqualStrings("build of /nix/store/a-x.drv failed: boom", es.failed.?);
}

test "lossy text as Rust's from_utf8_lossy" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("ok é", try text_.lossyAlloc(a, "ok é"));
    try testing.expectEqualStrings("a\u{fffd}b", try text_.lossyAlloc(a, "a\xffb"));
    // a truncated sequence is one replacement
    try testing.expectEqualStrings("a\u{fffd}b", try text_.lossyAlloc(a, "a\xe2\x82b"));
    try testing.expectEqualStrings("\u{fffd}\u{fffd}", try text_.lossyAlloc(a, "\xed\xa0"));
}

/// `iets print-dev-env`, from the command line's dispatch.
pub fn cmd(c: *const cli.Ctx, argv: []const []const u8) u8 {
    c.s.log.command = "print-dev-env";
    var a: args_mod.Args = .{ .s = c.s, .arena = c.init.arena.allocator(), .cmd = "print-dev-env", .argv = argv };
    const req = parse(&a) catch |e| return a.report(e);
    return run(c, &req);
}

/// `print-dev-env` of what `req` asks for: the native command, and classic
/// mode's `nix print-dev-env`.
pub fn run(c: *const cli.Ctx, req: *const Request) u8 {
    c.s.log.command = "print-dev-env";
    var impl: Hooks = .{ .c = c };
    defer impl.deinit();
    const dc: Ctx = .{ .s = c.s, .env_map = c.init.environ_map, .log = .of(&c.s.log) };
    return printDevEnv(&dc, &impl, req);
}
