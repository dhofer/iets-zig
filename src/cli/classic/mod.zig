//! Classic mode: iets installed under Nix's own command names, with an exec
//! fallback to the real binary for everything it does not implement.
//! See `docs/reference/classic.md`.
//!
//! Every command parses its own command line and gives up on what it does
//! not know with `Cmd.fallBack`: the reason, and then the real nix runs with
//! the same arguments. An `unsupported` evaluation error does the same.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const Diag = @import("../../diag.zig").Diag;
const Session = @import("../../session.zig").Session;
const log = @import("../../log.zig");
const errors = @import("../../errors.zig");
const config = @import("../../config.zig");
const settings_mod = @import("../../settings.zig");
const ignored = @import("../../ignored.zig");
const nixbin = @import("../../nixbin.zig");
const process = @import("../../sys/process.zig");
const Evaluator = @import("../../eval/Evaluator.zig");
const import_ = @import("../../eval/import.zig");
const Value = @import("../../runtime/value.zig").Value;
const remote = @import("../../remote.zig");
const worker = remote.worker;
const Transport = worker.Transport;
const api = @import("../../api.zig");
const lint = @import("../../lint.zig");
const cli = @import("../../cli.zig");
const args_mod = @import("../args.zig");

pub const instantiate = @import("instantiate.zig");
pub const build = @import("build.zig");
pub const shell = @import("shell.zig");
pub const nix = @import("nix.zig");
pub const drvshow = @import("drvshow.zig");
pub const develop = @import("develop.zig");
pub const fmt = @import("fmt.zig");

/// The classic names iets answers to: the tag is
/// the name.
pub const Name = enum {
    @"nix-instantiate",
    @"nix-build",
    @"nix-eval-jobs",
    @"nix-shell",
    nix,

    pub fn fromWord(word: []const u8) ?Name {
        return std.meta.stringToEnum(Name, word);
    }
};

/// Runs the classic command `name`. `argv` is everything after `argv[0]`
/// (or after the name, as `iets nix-build ...`).
pub fn dispatch(c: *const cli.Ctx, name: Name, argv: []const []const u8) u8 {
    c.s.log.setClassic();
    // no iets command: every error exits 1, as Nix's do
    c.s.log.command = null;
    return switch (name) {
        .@"nix-instantiate" => instantiate.main(c, argv),
        .@"nix-build" => build.main(c, argv),
        .@"nix-shell" => shell.main(c, argv),
        .@"nix-eval-jobs" => cli.jobs.cmd(c, argv),
        .nix => nix.main(c, argv),
    };
}

/// Why a command stops early: it falls back to the real nix (`Cmd.why`), or
/// it is done with an exit code it reported (`Cmd.code`).
pub const Stop = error{ Fallback, Exit, OutOfMemory };

/// One classic command: what the fallback needs, and why it stopped.
pub const Cmd = struct {
    c: *const cli.Ctx,
    s: *Session,
    arena: Allocator,
    /// The real binary the fallback runs: `nix-build`, `nix`, ...
    name: []const u8,
    /// Everything after `argv[0]`, for the fallback.
    argv: []const []const u8,
    why: []const u8 = "",
    code: u8 = 0,
    /// Where a run puts the `unsupported` error it met (`run`, `ran`).
    fallback: api.run.Fallback = .{},

    pub fn init(c: *const cli.Ctx, name: []const u8, argv: []const []const u8) Cmd {
        return .{ .c = c, .s = c.s, .arena = c.init.arena.allocator(), .name = name, .argv = argv };
    }

    /// Falls back with the reason `fmt`.
    pub fn fallBack(k: *Cmd, comptime f: []const u8, a: anytype) Stop {
        k.why = try std.fmt.allocPrint(k.arena, f, a);
        return error.Fallback;
    }

    /// Ends the command with `code`, already reported.
    pub fn exit(k: *Cmd, code: u8) Stop {
        k.code = code;
        return error.Exit;
    }

    /// `e` with the message on `d`, reported; ends the command.
    pub fn fail(k: *Cmd, d: *const Diag, e: anyerror) Stop {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return k.exit(report(k.s, d, e));
    }

    /// The exit code of a command body: a fallback execs the real nix.
    pub fn finish(k: *Cmd, r: Stop!u8) u8 {
        return r catch |e| switch (e) {
            error.Fallback => fallback(k.c, k.name, k.argv, k.why),
            error.Exit => k.code,
            error.OutOfMemory => k.exit(report(k.s, &.{ .gpa = k.s.gpa }, error.OutOfMemory)) catch k.code,
        };
    }
};

/// An error outside the evaluator, reported with its code; the exit code.
pub fn report(s: *Session, d: *const Diag, e: anyerror) u8 {
    const msg = d.msg orelse @errorName(e);
    const r: log.Report = .{ .code = errors.code(e), .raw = msg, .hint = d.hint };
    return r.emit(&s.log);
}

/// Execs the real `name` with the same arguments. `IETS_NO_FALLBACK=1`
/// makes this an error instead, so a test can see which cases fall back.
pub fn fallback(c: *const cli.Ctx, name: []const u8, argv: []const []const u8, reason: []const u8) noreturn {
    const s = c.s;
    const a = c.init.arena.allocator();
    s.log.textLine(std.fmt.allocPrint(a, "iets: falling back to {s}: {s}", .{ name, reason }) catch "iets: falling back");
    if (s.settings.no_fallback) {
        s.log.textLine(std.fmt.allocPrint(a, "iets: no-fallback is set, not running {s}", .{name}) catch "iets: no-fallback is set");
        std.process.exit(1);
    }
    const real = nixbin.real(a, s.io, s.env, s.settings.nix_bin_dir, name) orelse {
        s.log.err(std.fmt.allocPrint(a, "iets: cannot fall back to {s}: not found on PATH\n", .{name}) catch "iets: cannot fall back\n");
        std.process.exit(1);
    };
    const full = a.alloc([]const u8, argv.len + 1) catch std.process.exit(1);
    full[0] = name;
    @memcpy(full[1..], argv);
    // the process environment as it is now: `nix-shell` set `IN_NIX_SHELL`
    const e = process.execvpe(a, real, full, process.environ(), null);
    s.log.err(std.fmt.allocPrint(a, "iets: cannot exec '{s}': {f}\n", .{ real, errors.osErrno(e) }) catch "iets: cannot exec\n");
    std.process.exit(1);
}

/// Writes the command's stdout; a failed write is reported and ends it.
pub fn out(k: *Cmd, b: []const u8) Stop!void {
    k.s.out.writeAll(b) catch {
        const msg = try std.fmt.allocPrint(k.arena, "write of {d} bytes: {s}", .{ b.len, errors.errnoText(k.s.out.failure) });
        const r: log.Report = .{ .code = "io", .raw = msg };
        return k.exit(r.emit(&k.s.log));
    };
}

/// `out` for the legacy command names, which write through `std::cout` and
/// never look: `nix-instantiate` and `nix-build` exit 0 on a full disk.
pub fn outLossy(s: *Session, b: []const u8) void {
    s.out.writeAll(b) catch {};
}

/// The flags `nix-instantiate` and `nix-build` share (`MixEvalArgs` plus the
/// settings aliases of `LegacyArgs`).
pub const Common = struct {
    flags: args_mod.EvalFlags = .{},
    files: std.ArrayList([]const u8) = .empty,
    /// `-E`: the positional arguments are expressions, not paths.
    from_args: bool = false,
    quiet: bool = false,
};

/// A cursor over the command line; a flag without its value falls back,
/// because the real nix reports that better than a second usage message
/// would.
pub const Argv = struct {
    k: *Cmd,
    all: []const []const u8,
    i: usize = 0,

    pub fn value(a: *Argv, flag: []const u8) Stop![]const u8 {
        a.i += 1;
        if (a.i < a.all.len) return a.all[a.i];
        return a.k.fallBack("'{s}' requires an argument", .{flag});
    }

    /// `value`, for `args.evalFlag`.
    pub fn next(a: *Argv, flag: []const u8) Stop![]const u8 {
        return a.value(flag);
    }

    /// A value `args.evalFlag` refuses: the real nix says why.
    pub fn fail(a: *Argv, comptime f: []const u8, args: anytype) Stop {
        return a.k.fallBack(f, args);
    }

    /// `-j` and `--cores` set a setting, so the value is the setting's: an
    /// integer in a 32-bit field, and `auto` for `max-jobs`.
    fn number(a: *Argv, flag: []const u8, setting: []const u8) Stop![]const u8 {
        const v = try a.value(flag);
        var d: Diag = .init(a.k.arena);
        config.checkValue(setting, v, &d) catch return a.k.fallBack("{s}", .{d.message()});
        return v;
    }
};

/// True: consumed. False: not one of ours. `error.Fallback`: fall back.
pub fn commonFlag(cm: *Common, a: *Argv, x: []const u8) Stop!bool {
    if (try args_mod.evalFlag(a, &cm.flags, x)) return true;
    const flag = std.meta.stringToEnum(enum {
        @"-E",
        @"--expr",
        @"--store",
        @"--flake-registry",
        @"-j",
        @"--max-jobs",
        @"--cores",
        @"-k",
        @"--keep-going",
        @"-K",
        @"--keep-failed",
        @"--quiet",
        @"-v",
        @"--verbose",
        @"--no-gc-warning",
        @"--indirect",
    }, x) orelse return false;
    const arena = a.k.arena;
    const set = &cm.flags.overrides;
    switch (flag) {
        .@"-E", .@"--expr" => cm.from_args = true,
        .@"--store" => try set.append(arena, .{ .name = "store", .value = try a.value(x) }),
        .@"--flake-registry" => try set.append(arena, .{ .name = "flake-registry", .value = try a.value(x) }),
        .@"-j", .@"--max-jobs" => try set.append(arena, .{ .name = "max-jobs", .value = try a.number(x, "max-jobs") }),
        .@"--cores" => try set.append(arena, .{ .name = "cores", .value = try a.number(x, "cores") }),
        .@"-k", .@"--keep-going" => try set.append(arena, .{ .name = "keep-going", .value = "true" }),
        .@"-K", .@"--keep-failed" => try set.append(arena, .{ .name = "keep-failed", .value = "true" }),
        .@"--quiet" => cm.quiet = true,
        .@"-v", .@"--verbose" => try a.k.s.ignored.flag("--verbose", ignored.one_log_level),
        // `--indirect` does nothing in Nix either (nix-build.cc: "obsolete").
        // Only nix-instantiate has the GC warning, and it takes that flag itself.
        .@"--no-gc-warning", .@"--indirect" => {},
    }
    return true;
}

/// Where the builds go, from the `store` setting. `system` is the `system=`
/// default a `grpc://` URL takes.
pub fn transportOf(k: *Cmd, url: []const u8, system: []const u8) Stop!Transport {
    const env = k.c.init.environ_map;
    if (url.len == 0 or std.mem.eql(u8, url, "auto") or std.mem.eql(u8, url, "daemon"))
        return .{ .unix = try worker.defaultSocket(k.arena, env) };
    const sw = std.mem.startsWith;
    if (sw(u8, url, "unix://") or sw(u8, url, "ssh-ng://") or sw(u8, url, "grpc://")) {
        var d: Diag = .init(k.arena);
        const t = worker.Transport.parseChecked(k.arena, url, system, env, &d) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return k.fallBack("{s}", .{d.message()}),
        };
        return t orelse k.fallBack("cannot parse the store URL '{s}'", .{url});
    }
    return k.fallBack("store '{s}' is not supported; iets speaks the worker protocol and grpc:// only", .{url});
}

/// nix.conf and what a command needs of it: where the builds go and the
/// `SetOptions` values.
pub const Settings = struct {
    cfg: *const config.Config,
    transport: Transport,
    options: worker.Options,
};

/// `Config::load` plus the transport and `SetOptions` values it implies. The
/// build target is `--store` or `--option store` when the command line gave
/// one, else the `builder` setting, else nix.conf's `store`
/// (docs/reference/settings.md). `use_builder` false is for a command that
/// builds nothing on a builder: a shell, whose inputs belong in the local
/// store where it runs, and `nix-instantiate`; `--store` still wins.
pub fn settings(k: *Cmd, cm: *const Common, use_builder: bool) Stop!Settings {
    const s = k.s;
    var d: Diag = .init(s.gpa);
    defer d.deinit();
    // a nix.conf Nix itself refuses is no reason to hand it to Nix: it stops
    // at the same value with the same text (config-impl.hh:151)
    var cfg = config.Config.read(s.gpa, s.io, s.env, cm.flags.overrides.items, &d) catch |e| return k.fail(&d, e);
    if (cfg.leftToNix()) |name| {
        cfg.deinit();
        return k.fallBack("the setting '{s}' is not implemented", .{name});
    }
    // Config::announce
    cfg.noteIgnored(&s.ignored) catch {};
    if (cfg.boolean("show-trace", &d) catch null orelse false) s.log.setShowTrace();
    if (s.nix_conf) |*old| old.deinit();
    s.nix_conf = cfg;
    s.ignored.flush();
    const conf = &s.nix_conf.?;

    var url = conf.store();
    if (use_builder) {
        const flag: ?[]const u8 = if (storeGiven(cm)) conf.store() else null;
        // Classic mode addresses one store, as the tool it stands in for
        // does. Placing across several is `iets build`'s (docs/reference/classic.md).
        const specs = try settings_mod.builders(k.arena, flag, &s.settings, conf);
        if (specs.len > 1) {
            var rest: std.ArrayList(u8) = .empty;
            for (specs[1..], 0..) |sp, i| {
                if (i > 0) try rest.appendSlice(k.arena, ", ");
                try rest.appendSlice(k.arena, sp.url);
            }
            s.log.textLine(try std.fmt.allocPrint(k.arena, "warning: classic mode builds on one place: using '{s}', ignoring {s}", .{ specs[0].url, rest.items }));
        }
        if (specs.len > 0) url = specs[0].url;
    }
    const transport = try transportOf(k, url, conf.system());
    if (transport == .grpc) config.noteGrpc(&s.ignored, cm.flags.overrides.items) catch {};
    const options = worker.Options.fromConfig(k.arena, conf, &d) catch |e| return k.fail(&d, e);
    return .{ .cfg = conf, .transport = transport, .options = options };
}

/// `--store` names the store the outputs belong to. Without it the builder
/// stands in for the local store, as a build hook does, so outputs come back
/// even under `--no-link`.
pub fn storeGiven(cm: *const Common) bool {
    for (cm.flags.overrides.items) |o| if (std.mem.eql(u8, o.name, "store")) return true;
    return false;
}

/// The local daemon, where GC roots, out-links and `--add-root`
/// registrations go whatever `builder` says (docs/reference/classic.md).
pub fn local(k: *Cmd) Stop!Transport {
    return .{ .unix = try worker.defaultSocket(k.arena, k.c.init.environ_map) };
}

/// `f` made absolute against the working directory.
pub fn absPath(k: *Cmd, f: []const u8) Stop![]const u8 {
    return api.absPath(k.arena, try cwd(k), f);
}

pub fn cwd(k: *Cmd) Stop![]const u8 {
    return std.process.currentPathAlloc(k.s.io, k.arena) catch "/";
}

/// The evaluator configuration: the search
/// path with nix.conf's `nix-path`, the `system` setting and `pure-eval`,
/// no lints. `entry` is the file the walk to the project root starts from.
pub fn evalArgs(k: *Cmd, cm: *const Common, cfg: *const config.Config) Stop!api.EvalArgs {
    var d: Diag = .init(k.arena);
    const pure = cm.flags.pure orelse (cfg.boolean("pure-eval", &d) catch null) orelse false;
    var a: api.EvalArgs = .{
        .includes = cm.flags.includes.items,
        .args = cm.flags.args.items,
        .attrs = cm.flags.attrs.items,
        .pure = pure,
        .no_tracing_cache = !k.s.settings.cache,
        .no_ir_cache = !k.s.settings.cache,
    };
    // the root alone feeds the project walk
    if (!cm.from_args and cm.files.items.len > 0) a.input = .{ .file = cm.files.items[0] };
    return a;
}

/// The classic part of a run's configuration: the search path is the
/// `-I`s, then `NIX_PATH` unless `nix-path` replaces it, then `nix-path`.
pub fn classicRun(k: *Cmd, cm: *const Common, cfg: *const config.Config, pure: bool) Stop!api.run.Classic {
    const nix_path = if (cfg.nixPathReplaces()) null else k.s.env.get("NIX_PATH");
    const search = try api.searchPath(k.arena, try cwd(k), cm.flags.includes.items, nix_path, cfg);
    return .{ .system = cfg.system(), .pure = pure, .search_path = search };
}

/// The run of one classic command: the evaluator `evalArgs` and
/// `classicRun` configure.
pub fn run(k: *Cmd, cm: *const Common, cfg: *const config.Config, a: *api.EvalArgs) Stop!api.run.Run {
    const cls = try k.arena.create(api.run.Classic);
    cls.* = try classicRun(k, cm, cfg, a.pure.?);
    return .{ .s = k.s, .init = k.c.init, .args = a, .classic = cls, .fallback = &k.fallback };
}

/// The exit code of a run, or the fallback an `unsupported` error asks for.
pub fn ran(k: *Cmd, code: u8) Stop!u8 {
    if (k.fallback.why) |why| {
        k.why = why;
        return error.Fallback;
    }
    return code;
}

/// `lookupFileArg`: `<name>` goes through the search path, anything else is
/// a path relative to the working directory.
pub fn lookupFileArg(ev: *Evaluator, a: Allocator, f: []const u8, dir: []const u8) Evaluator.Error![]const u8 {
    if (f.len > 2 and f[0] == '<' and f[f.len - 1] == '>')
        return import_.findFile(ev, ev.config.search_path, f[1 .. f.len - 1], .none);
    return api.absPath(a, dir, f) catch error.OutOfMemory;
}

/// One of the positional arguments, evaluated: an expression under `-E`,
/// otherwise a file (a directory resolves to its `default.nix`).
pub fn evalInput(ev: *Evaluator, a: Allocator, cm: *const Common, file: []const u8, dir: []const u8) Evaluator.Error!Value {
    if (cm.from_args) return import_.evalString(ev, file);
    const p = try lookupFileArg(ev, a, file, dir);
    return import_.evalFile(ev, p, .none);
}

/// An `unsupported` error the caller turns into a fallback.
pub fn unsupported(ev: *Evaluator, comptime f: []const u8, a: anytype) Evaluator.Error {
    return ev.fail(.unsupported, .none, f, a);
}

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

/// The tracing cache of a classic run: `key` is
/// what changes the answer, `more` the installables after the first. Off
/// when the cache is, or the arguments cannot be keyed.
pub fn openCache(k: *Cmd, r: *api.run.Run, key: *const api.EvalArgs, subcommand: []const u8, more: []const []const u8) void {
    r.cache = api.cache.openFor(k.s, k.c.init, key, subcommand, more, r.classic) catch null;
}

/// The input store a hit validates against and plans from; the caller
/// `deinit`s it.
pub fn inputStore(k: *Cmd, cache_dir: ?[]const u8) !*treestore.Store {
    return api.cache.inputStore(k.arena, k.s, k.c.init.environ_map, cache_dir);
}

fn hit(k: *Cmd, tc: *api.cache.Cache, inputs: *treestore.Store) bool {
    return api.cache.hit(k.s, tc, inputs);
}

/// The stdout a valid entry remembers (`Run::hit_result`).
pub fn hitResult(k: *Cmd, r: *const api.run.Run, inputs: *treestore.Store) ?[]const u8 {
    const tc = r.cache orelse return null;
    if (!hit(k, tc, inputs)) return null;
    return tc.part(.result);
}

/// A `build` entry a valid entry remembers: its roots, and the tables the
/// plan reads (`Run::hit_plan`). A part that does not decode is a miss and
/// discards the entry.
pub const PlanHit = struct {
    roots: []const trace_wire.Root,
    tables: *api.cache.Tables,
};

pub fn hitPlan(k: *Cmd, r: *const api.run.Run, inputs: *treestore.Store) ?PlanHit {
    const tc = r.cache orelse return null;
    if (!hit(k, tc, inputs)) return null;
    const decoded: ?PlanHit = blk: {
        const rb = tc.part(.result) orelse break :blk null;
        const db = tc.part(.drvs) orelse break :blk null;
        const sb = tc.part(.sources) orelse break :blk null;
        const roots = (trace_wire.decodeRoots(k.arena, rb) catch break :blk null) orelse break :blk null;
        const t = k.arena.create(api.cache.Tables) catch break :blk null;
        t.* = (api.cache.Tables.decode(k.arena, db, sb, inputs) catch break :blk null) orelse break :blk null;
        break :blk .{ .roots = roots, .tables = t };
    };
    const h = decoded orelse {
        tc.discardTables();
        return null;
    };
    tc.replayWarnings() catch {};
    return h;
}

const treestore = @import("../../treestore.zig");
const trace_wire = @import("../../trace.zig").wire;
