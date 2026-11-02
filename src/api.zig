//! What the commands share below their command lines: the evaluation input,
//! one run of the evaluator, the error report.
//!

const std = @import("std");
const Allocator = std.mem.Allocator;
/// The evaluator a run hands its callback, for a frontend to name.
pub const Evaluator = @import("eval/Evaluator.zig");
const rt = @import("runtime/value.zig");
const Value = rt.Value;
const Diag = @import("diag.zig").Diag;
const import_ = @import("eval/import.zig");
const Session = @import("session.zig").Session;
const config = @import("config.zig");
const log = @import("log.zig");
const provenance = @import("provenance.zig");
const store_path = @import("store/path.zig");
const StorePath = store_path.StorePath;
const project = @import("project.zig");

pub const run = @import("api/run.zig");
pub const cache = @import("api/cache.zig");
pub const installable = @import("api/installable.zig");
pub const build = @import("api/build.zig");
pub const render = @import("api/render.zig");
pub const drvshow = @import("api/drvshow.zig");
pub const fetch = @import("api/fetch.zig");
pub const value = @import("api/value.zig");
pub const watch = @import("api/watch.zig");
pub const testkit = @import("api/testkit.zig");
pub const Instance = @import("api/instance.zig").Instance;

/// The stack of the demand fiber and of the thread a run starts: the demand
/// path has the same room at every worker count, or a program that works
/// with one worker crashes with four.
pub const main_stack = Evaluator.Pool.main_stack;
pub const flake = @import("api/flake.zig");

pub const Input = union(enum) {
    expr: []const u8,
    file: []const u8,
    /// `DIR#attr.path`.
    flake: []const u8,

    /// What names it in a label or a message: the expression, file or flake.
    pub fn text(i: Input) []const u8 {
        return switch (i) {
            inline else => |t| t,
        };
    }
};

/// `--arg NAME EXPR` or `--argstr NAME STRING`.
pub const AutoArg = struct { name: []const u8, text: []const u8, is_str: bool };

const lint = @import("lint.zig");

/// Everything one evaluation needs; `parseEvalFlag` (cli/args.zig) fills it
/// from a command line. Strings live in the run's arena.
pub const EvalArgs = struct {
    strict: bool = false,
    json: bool = false,
    raw: bool = false,
    /// `-I` entries as given.
    includes: []const []const u8 = &.{},
    args: []const AutoArg = &.{},
    input: ?Input = null,
    /// Installables before `input`. Only `iets build` uses them.
    more: []const Input = &.{},
    attr: ?[]const u8 = null,
    /// Every `-A` in order; `attr` is the last.
    attrs: []const []const u8 = &.{},
    /// Evaluator threads, the main one included; 0 takes the `workers`
    /// setting, else the cores, at most 4.
    workers: u32 = 0,
    timings: bool = false,
    /// `--no-tracing-cache`: evaluate, never replay a run.
    no_tracing_cache: bool = false,
    /// `--no-ir-cache`: compile every import from source.
    no_ir_cache: bool = false,
    cache_dir: ?[]const u8 = null,
    /// The last of `--pure-eval`, `--no-pure-eval`, `--impure` and
    /// `--option pure-eval`; null takes the `pure` setting.
    pure: ?bool = null,
    parse_toml_timestamps: bool = false,
    /// `--lint SELECTOR=LEVEL` in order; applied after `iets.toml` and
    /// `IETS_LINT` (docs/reference/lints.md).
    lints: []const lint.Flag = &.{},
    /// `--lint-root DIR`: lint roots after the entry directory.
    lint_roots: []const []const u8 = &.{},
    /// `--lint-scope root|all`; null keeps `iets.toml`'s or the default.
    lint_scope: ?lint.Scope = null,
    /// `eval-jobs --flake DIR` with no fragment: the whole `callFlake`
    /// result, not its `outputs`.
    flake_whole: bool = false,
    reference_lock_file: ?[]const u8 = null,
    /// `--dump-drvs DIR`: every derivation the run makes is written there as
    /// ATerm, so another process can plan a closure in no store.
    dump_drvs: ?[]const u8 = null,
    /// `--extra-experimental-features` as given, one feature each; only
    /// `parse-toml-timestamps` changes an evaluation.
    xp_features: []const []const u8 = &.{},

    /// The `parse-toml-timestamps` experimental feature, by either field.
    pub fn tomlTimestamps(a: *const EvalArgs) bool {
        if (a.parse_toml_timestamps) return true;
        for (a.xp_features) |f| if (std.mem.eql(u8, f, "parse-toml-timestamps")) return true;
        return false;
    }
};

/// `f` absolute against `cwd`, canonical; in `a`.
pub fn absPath(a: Allocator, cwd: []const u8, f: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, f, "/") or std.mem.indexOf(u8, f, "://") != null) return f;
    return Evaluator.canonPath(a, try std.mem.concat(a, u8, &.{ cwd, "/", f }));
}

/// Sets the store directory every store path hash takes as input from the
/// session's `NIX_STORE_DIR` (or `NIX_STORE`), warning on one that is not
/// absolute. Call it once, before the first store path is made: the store
/// directory is process-wide. `a` must outlive every evaluation.
pub fn initStoreDir(s: *Session, a: Allocator) !void {
    const set = s.env.nonEmpty("NIX_STORE_DIR") orelse s.env.nonEmpty("NIX_STORE");
    const r = store_path.resolveStoreDir(try a.alloc(u8, 256), set, s.env.nonEmpty("PROGRAMDATA"), false);
    if (r.ignored) s.log.errln(try std.fmt.allocPrint(a, "warning: ignoring NIX_STORE_DIR '{s}', it is not an absolute path", .{set.?}));
    store_path.store_dir = try a.dupe(u8, r.dir);
}

/// The working directory, or `/` when it cannot be read; in `a`.
pub fn workingDir(io: std.Io, a: Allocator) ![]const u8 {
    return std.process.currentPathAlloc(io, a) catch |e| switch (e) {
        error.OutOfMemory => e,
        else => "/",
    };
}

/// A `-I prefix=path` (or `-I path`) entry as an absolute pair.
pub fn searchEntry(a: Allocator, cwd: []const u8, s: []const u8) !Evaluator.SearchPathEntry {
    if (std.mem.indexOfScalar(u8, s, '=')) |eq| return .{ .prefix = s[0..eq], .path = try absPath(a, cwd, s[eq + 1 ..]) };
    return .{ .prefix = "", .path = try absPath(a, cwd, s) };
}

/// The directory the project walk starts from: the entry file's
/// directory, the flake directory, else cwd.
pub fn entryDir(a: Allocator, io: std.Io, args: *const EvalArgs, cwd: []const u8) ![]const u8 {
    if (args.input) |i| switch (i) {
        .file => |f| return import_.dirOf(try absPath(a, cwd, f)),
        .flake => |f| {
            var d: Diag = .init(a);
            if (flake.flakeRef(a, io, f, cwd, &d)) |fr| return fr.dir else |_| {}
        },
        .expr => {},
    };
    return cwd;
}

/// The project this run's sources belong to: the root `project.find` gives
/// at or above `entryDir`, else that directory. A flake gets none: its root
/// tree is already a filtered store copy, and an unfiltered second root
/// would let it read an untracked file by its absolute path
/// (docs/explanation/flakes-and-sources.md).
pub fn projectRoot(a: Allocator, io: std.Io, args: *const EvalArgs, cwd: []const u8) !?[]const u8 {
    if (args.input) |i| if (i == .flake) return null;
    const dir = try entryDir(a, io, args, cwd);
    return @import("project.zig").find(dir) orelse dir;
}

/// The lint configuration of a run (docs/reference/lints.md): the entry's
/// directory starts the `iets.toml` walk and is the first lint root. The
/// notes it makes are the caller's to print; a configuration that does not
/// resolve is `error.BadConfig` with its message in `d`.
pub fn lintConfig(a: Allocator, io: std.Io, env: lint.Env, args: *const EvalArgs, cwd: []const u8, notes: *lint.Notes, d: *Diag) (Allocator.Error || error{BadConfig})!lint.Config {
    const start = try entryDir(a, io, args, cwd);
    const roots = try a.alloc([]const u8, args.lint_roots.len);
    for (args.lint_roots, roots) |x, *o| o.* = try absPath(a, cwd, x);
    return lint.Config.resolve(a, io, env, start, args.lints, roots, args.lint_scope, notes, d);
}

/// The search path as absolute pairs in `a`: the `-I` entries, then
/// `nix_path` (the `NIX_PATH` that applies, if any), then the `nix-path`
/// setting of `conf`. Nix's channel defaults are not here.
pub fn searchPath(a: Allocator, cwd: []const u8, includes: []const []const u8, nix_path: ?[]const u8, conf: ?*const config.Config) ![]Evaluator.SearchPathEntry {
    var all: std.ArrayList(Evaluator.SearchPathEntry) = .empty;
    for (includes) |inc| try all.append(a, try searchEntry(a, cwd, inc));
    if (nix_path) |np| {
        var it = std.mem.tokenizeScalar(u8, np, ':');
        while (it.next()) |e| try all.append(a, try searchEntry(a, cwd, e));
    }
    if (conf) |c| {
        var it = c.list("nix-path");
        while (it.next()) |e| try all.append(a, try searchEntry(a, cwd, e));
    }
    return all.items;
}

/// A parsed `DIR#attr.path` (`api/flake.zig`).
pub const FlakeRef = flake.FlakeRef;

/// `DIR#attr.path` against `cwd`, the home directory for `~`.
pub const flakeRef = flake.flakeRef;

/// Evaluates the input, `--arg`s and `-A` included.
/// A flake loads once per run, however many installables name it: the
/// loads live in `ev.shared.flakes`.
pub fn evaluate(ev: *Evaluator, a: Allocator, args: *const EvalArgs, cwd: []const u8) Evaluator.Error!Value {
    const root = try input(ev, a, args, cwd);
    const auto = try autoArgs(ev, a, args.args);
    return select(ev, root, args.attr, auto, args.args.len > 0);
}

/// `evaluate` for each `-A` in order. The input and the `--arg`s are
/// evaluated once, as in `nix-instantiate --eval`.
pub fn evaluateEach(ev: *Evaluator, a: Allocator, args: *const EvalArgs, cwd: []const u8, ctx: anytype, comptime each: fn (@TypeOf(ctx), *Evaluator, Value) Evaluator.Error!void) Evaluator.Error!void {
    const root = try input(ev, a, args, cwd);
    const auto = try autoArgs(ev, a, args.args);
    const has = args.args.len > 0;
    if (args.attrs.len == 0) return each(ctx, ev, try select(ev, root, args.attr, auto, has));
    for (args.attrs) |attr| try each(ctx, ev, try select(ev, root, attr, auto, has));
}

fn select(ev: *Evaluator, root: Value, attr: ?[]const u8, auto: *rt.Attrs, has_args: bool) Evaluator.Error!Value {
    if (attr) |p| return installable.findAlongAttrPath(ev, root, p, auto);
    // nix-instantiate.cc: no attribute path, so the top level is called only
    // when there is something to call it with
    if (has_args) return ev.autoCall(root, auto);
    return root;
}

/// The value of the input itself, before `--arg` and `-A`.
pub fn input(ev: *Evaluator, a: Allocator, args: *const EvalArgs, cwd: []const u8) Evaluator.Error!Value {
    const i = args.input orelse return ev.fail(.eval, .none, "nothing to evaluate: no expression, file or flake", .{});
    return switch (i) {
        .expr => |e| import_.evalString(ev, e),
        .file => |f| import_.evalFile(ev, absPath(a, cwd, f) catch return error.OutOfMemory, .none),
        .flake => |f| flake.input(ev, a, f, cwd, args.reference_lock_file, args.flake_whole),
    };
}

/// The `--arg`/`--argstr` attrset (`nix-instantiate`'s autoArgs).
/// common-eval-args.cc keeps autoArgs in a map and insert_or_assign's into
/// it, so the last `--arg`/`--argstr` of a name is the one that is used.
pub fn autoArgs(ev: *Evaluator, a: Allocator, args: []const AutoArg) Evaluator.Error!*rt.Attrs {
    var entries: std.ArrayList(rt.Attr) = .empty;
    defer entries.deinit(a);
    var i = args.len;
    while (i > 0) {
        i -= 1;
        const arg = args[i];
        var later = false;
        for (args[i + 1 ..]) |o| if (std.mem.eql(u8, o.name, arg.name)) {
            later = true;
        };
        if (later) continue;
        // compiled now, so a syntax error is reported before anything runs,
        // and evaluated only when the program asks (`nix-instantiate --eval`
        // prints an unforced one as `<CODE>`)
        const v = if (arg.is_str) try ev.mkString(arg.text) else blk: {
            const code = try import_.compileSource(ev, "«arg»", arg.text, ev.config.cwd, null);
            break :blk try ev.mkThunk(ev.root_env, code);
        };
        try entries.append(a, .{ .sym = try ev.sym(arg.name), .pos = .none, .cell = .init(v) });
    }
    std.mem.reverse(rt.Attr, entries.items);
    return (try ev.mkAttrs(entries.items, .none)).as(rt.Attrs);
}

/// The derivations to build and the outputs to print: `wanted` plus the
/// outputs the roots' string context named.
pub fn buildTargets(a: Allocator, wanted: []const []const u8, roots: []const installable.DrvRoot) !struct { paths: []StorePath, outputs: []const []const u8 } {
    var outputs: std.ArrayList([]const u8) = .empty;
    try outputs.appendSlice(a, wanted);
    for (roots) |r| if (r.output) |o| {
        for (outputs.items) |x| {
            if (std.mem.eql(u8, x, o)) break;
        } else try outputs.append(a, o);
    };
    const paths = try a.alloc(StorePath, roots.len);
    for (roots, paths) |r, *p| p.* = r.drv;
    return .{ .paths = paths, .outputs = outputs.items };
}

/// An evaluation error as a report a host can render itself: positions and the store paths inside the messages
/// name the local file a source was copied from, when one is known
/// (docs/explanation/provenance.md). The lint warnings so far are flushed
/// first. Strings are in `arena`.
pub fn reportOf(ev: *Evaluator, s: *const Session, arena: Allocator) !log.Report {
    lint.report.flush(ev);
    const f = ev.failure orelse return .{ .code = "eval", .raw = "unknown failure" };
    var map: ?provenance.SourceMap = if (s.settings.provenance)
        try .fromEval(arena, ev, s.settings.source_map)
    else
        null;
    defer if (map) |*m| m.deinit();
    const m: ?*const provenance.SourceMap = if (map) |*x| x else null;
    const rewrite = struct {
        fn go(a: Allocator, mp: ?*const provenance.SourceMap, text: []const u8) ![]const u8 {
            const x = mp orelse return a.dupe(u8, text);
            return x.rewriteAlloc(a, text);
        }
    }.go;
    // a lint message resolves its own paths (lint/report.zig)
    var msg = if (f.kind == .lint) try arena.dupe(u8, f.msg) else try rewrite(arena, m, f.msg);
    // input fetch errors open with "iets: "; after
    // "error: " that only doubles
    if (std.mem.startsWith(u8, msg, "iets: ")) msg = msg["iets: ".len..];
    const trace = try arena.alloc(log.TraceEntry, f.trace.items.len);
    for (f.trace.items, trace) |t, *e| e.* = .{
        .msg = try rewrite(arena, m, t.msg),
        .pos = if (t.pos == .none) null else try provenance.errorPos(arena, ev, m, t.pos),
    };
    return .{
        .code = f.kind.code(),
        .raw = msg,
        .pos = if (f.pos == .none) null else try provenance.errorPos(arena, ev, m, f.pos),
        .trace = trace,
        .hint = if (f.hint) |h| try arena.dupe(u8, h) else null,
        .site = if (f.kind == .lint) try lintSite(ev, arena, f.msg, f.pos) else null,
    };
}

/// The site of a lint error, named by its `[name]` prefix.
fn lintSite(ev: *Evaluator, arena: Allocator, msg: []const u8, pos: @import("syntax.zig").Pos) !?log.Site {
    if (!std.mem.startsWith(u8, msg, "[")) return null;
    const end = std.mem.indexOfScalar(u8, msg, ']') orelse return null;
    const id = lint.byName(msg[1..end]) orelse return null;
    const st = (try lint.report.siteOf(ev, arena, id, pos)) orelse return null;
    return .{ .start = st.start, .end = st.end, .replacement = st.replacement };
}

/// `reportOf`, sent to the session's log. Returns the exit code.
pub fn report(ev: *Evaluator, s: *Session, arena: Allocator) !u8 {
    const r = try reportOf(ev, s, arena);
    return r.emit(&s.log);
}

/// `IETS_STATS=1`: the evaluator's counters on stderr (one line of
/// totals, then the arena by kind); `IETS_STATS=files`
/// also lists every file loaded, and level 2 the memory census.
pub fn printStats(ev: *Evaluator, env: *const std.process.Environ.Map) void {
    @import("eval/stats.zig").print(ev);
    if (ev.config.session.?.settings.stats >= 2) ev.printCensus();
    if (env.get("IETS_STATS")) |stats| if (std.mem.eql(u8, stats, "files")) for (ev.files.files.items) |f| ev.log("file {s}", .{f.path});
}

/// Nix has no activity for evaluation, so this is `actUnknown`:
/// `evaluating 'FILE' -A ATTR`.
pub fn evaluating(s: *Session, a: Allocator, args: *const EvalArgs) !log.Activity {
    const what: []const u8 = if (args.input) |i| switch (i) {
        .flake, .file => |f| try std.fmt.allocPrint(a, "'{s}'", .{f}),
        .expr => "the expression",
    } else "";
    const attr: []const u8 = if (args.attr) |p| try std.fmt.allocPrint(a, " -A {s}", .{p}) else "";
    const text = try std.fmt.allocPrint(a, "evaluating {s}{s}", .{ what, attr });
    return s.log.activity(0, log.lvl_talkative, log.act_unknown, text, &.{});
}

test "includes come first, then NIX_PATH, each made absolute" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const all = try searchPath(arena.allocator(), "/cwd", &.{ "a=x/../y", "/z" }, "nixpkgs=/n:rel::/plain", null);
    const want = [_][2][]const u8{ .{ "a", "/cwd/y" }, .{ "", "/z" }, .{ "nixpkgs", "/n" }, .{ "", "/cwd/rel" }, .{ "", "/plain" } };
    try std.testing.expectEqual(want.len, all.len);
    for (want, all) |w, e| {
        try std.testing.expectEqualStrings(w[0], e.prefix);
        try std.testing.expectEqualStrings(w[1], e.path);
    }
}

test "the entry directory and the project root follow the input" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("/w/sub", try entryDir(a, std.testing.io, &.{ .input = .{ .file = "sub/f.nix" } }, "/w"));
    try std.testing.expectEqualStrings("/w", try entryDir(a, std.testing.io, &.{ .input = .{ .expr = "1" } }, "/w"));
    try std.testing.expect((try projectRoot(a, std.testing.io, &.{ .input = .{ .flake = ".#x" } }, "/w")) == null);
    // no marker at or above a directory that does not exist: the directory itself
    try std.testing.expectEqualStrings("/nonexistent/iets/p", (try projectRoot(a, std.testing.io, &.{ .input = .{ .file = "p/f.nix" } }, "/nonexistent/iets")).?);
}

test "parse-toml-timestamps by either field" {
    try std.testing.expect(!(EvalArgs{}).tomlTimestamps());
    try std.testing.expect((EvalArgs{ .xp_features = &.{ "flakes", "parse-toml-timestamps" } }).tomlTimestamps());
    try std.testing.expect((EvalArgs{ .parse_toml_timestamps = true }).tomlTimestamps());
}

test "an error report is a value; the trace keeps its order" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const s = try Session.create(gpa, std.testing.io, .{});
    defer s.destroy();
    const inst = try Instance.create(gpa, std.testing.io, .{ .session = s });
    defer inst.destroy();
    try std.testing.expectError(error.EvalFailed, evaluate(&inst.ev, arena.allocator(), &.{ .input = .{ .expr = "let f = x: throw \"no ${x}\"; in f \"way\"" } }, "/"));
    const r = try reportOf(&inst.ev, s, arena.allocator());
    try std.testing.expectEqualStrings("throw", r.code);
    try std.testing.expectEqualStrings("no way", r.raw);
    try std.testing.expect(r.trace.len > 0);
    const text = try r.text(arena.allocator());
    try std.testing.expect(std.mem.startsWith(u8, text, "error: no way\n"));
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(value);
    std.testing.refAllDecls(watch);
    std.testing.refAllDecls(testkit);
    std.testing.refAllDecls(@import("api/instance.zig"));
    _ = @import("api/concurrent_eval.zig");
}
