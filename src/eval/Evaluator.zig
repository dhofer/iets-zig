//! The tree-walking evaluator over IR: forcing, application, the `with` chain,
//! operators, equality and string coercion.

const std = @import("std");
const builtin = @import("builtin");
const Evaluator = @This();

const value = @import("../runtime/value.zig");
const Value = value.Value;
const Cell = value.Cell;
const Env = value.Env;
const Ctx = value.Ctx;
const Arena = @import("../runtime/Arena.zig");
pub const census = @import("../runtime/census.zig");
const Scratch = @import("../Scratch.zig");
const bytes_ = @import("../bytes.zig");
const ir = @import("ir.zig");
const Ir = ir.Ir;
const Sym = @import("../syntax/symbol.zig").Sym;
const Interner = @import("../syntax/symbol.zig").Interner;
const Pos = @import("../syntax/pos.zig").Pos;
const Files = @import("Files.zig");
const print = @import("print.zig");
const import_ = @import("import.zig");
const store_hooks = @import("../builtins/store_hooks.zig");
pub const Shared = @import("Shared.zig");
pub const Pool = @import("Pool.zig");
const derivation = @import("../builtins/derivation.zig");
pub const lint_mod = @import("../lint.zig");
const lint_report = lint_mod.report;
pub const effects = @import("effects.zig");
const profile = @import("../profile.zig");

pub const Error = error{ EvalFailed, OutOfMemory };

pub const ErrorKind = enum {
    eval,
    type,
    /// `builtins.throw`; caught by `tryEval`.
    throw,
    /// A failed `assert`; caught by `tryEval`.
    assert,
    /// `builtins.abort`; never caught.
    abort,
    undefined_var,
    infinite_recursion,
    stack_overflow,
    parse,
    missing_attr,
    io,
    /// A feature iets does not implement; the classic commands run the real nix.
    unsupported,
    hash_mismatch,
    /// A helper gave up its task; never caught, never reported.
    cancelled,
    /// A lint at level `error`; never caught by `tryEval`.
    lint,

    /// The stable code of docs/reference/errors.md.
    pub fn code(k: ErrorKind) []const u8 {
        return switch (k) {
            .undefined_var => "undefined-var",
            .infinite_recursion => "infinite-recursion",
            .stack_overflow => "stack-overflow",
            .missing_attr => "missing-attr",
            .hash_mismatch => "hash-mismatch",
            else => @tagName(k),
        };
    }
};

pub const TraceLine = struct { pos: Pos, msg: []u8 };

/// The error being propagated. One at a time: `tryEval` clears it when it
/// catches, and the command line reports it when it reaches the top.
pub const Failure = struct {
    kind: ErrorKind,
    msg: []u8,
    pos: Pos,
    trace: std.ArrayList(TraceLine) = .empty,
    /// What to do about it: the record's `hint`, and the text's last line
    /// for an `unsupported` error.
    hint: ?[]u8 = null,
};

/// Symbols the evaluator looks up by name.
pub const WellKnown = struct {
    outPath: Sym,
    /// Interned right after the static symbols, where Rust iets interns it,
    /// so a set's order matches its; `select_count` and `getAttr` compare it.
    revCount: Sym,
    drvPath: Sym,
    type: Sym,
    name: Sym,
    value: Sym,
    file: Sym,
    line: Sym,
    column: Sym,
    __functor: Sym,
    __toString: Sym,
    __overrides: Sym,
    derivation: Sym,
    outputs: Sym,
    outputName: Sym,
    system: Sym,
    builder: Sym,
    args: Sym,
    meta: Sym,
    success: Sym,
    right: Sym,
    wrong: Sym,
    key: Sym,
    operator: Sym,
    startSet: Sym,
    path: Sym,
    prefix: Sym,
    data: Sym,
};

/// The symbols Nix 2.34.8 creates before any other, in its order
/// (eval.hh, `StaticEvalSymbols::preallocate`). A set's attributes are in
/// symbol order, and `==` on two sets compares them in that order, so
/// which of a differing and a throwing attribute it meets first depends on
/// it: `{ a = 1; meta = throw "t"; } == { a = 2; meta = 1; }` throws in
/// Nix. The names must stay first and in this order.
const nix_static_symbols = [_][]const u8{
    "<with>",
    "outPath",
    "drvPath",
    "type",
    "meta",
    "name",
    "value",
    "system",
    "__overrides",
    "outputs",
    "outputName",
    "__ignoreNulls",
    "file",
    "line",
    "column",
    "__functor",
    "__toString",
    "right",
    "wrong",
    "__structuredAttrs",
    "__json",
    "allowedReferences",
    "allowedRequisites",
    "disallowedReferences",
    "disallowedRequisites",
    "maxSize",
    "maxClosureSize",
    "builder",
    "args",
    "__contentAddressed",
    "__impure",
    "outputHash",
    "outputHashAlgo",
    "outputHashMode",
    "recurseForDerivations",
    "description",
    "self",
    "",
    "startSet",
    "operator",
    "key",
    "path",
    "prefix",
    "outputSpecified",
    "__sub",
    "__lessThan",
    "__mul",
    "__div",
    "or",
    "__findFile",
    "__nixPath",
    "body",
};

/// Nix's default max-call-depth.
pub const max_call_depth = 10000;

/// IR nodes a thread shares: `locals[depth][idx]`, and recent constants by a
/// hash of their word (a collision only makes a node of its own).
pub const SharedIr = struct {
    locals: [16][64]?ir.Ref = @splat(@splat(null)),
    /// The word is kept beside the node, so a probe reads no node.
    consts: [4096]struct { word: u64 = 0, node: ?ir.Ref = null } = @splat(.{}),
};

/// What a thread owns and lends to the evaluator it runs: allocation and
/// caches no two threads may touch at once. Values made from it are global
/// and live until the owner goes.
pub const Local = struct {
    arena: Arena,
    /// Every context-free string by content: one object per distinct text.
    /// Keyed by the 64-bit hash of the bytes, so growing the table never
    /// reads them again; a colliding text simply stays unshared.
    strings: std.AutoHashMapUnmanaged(u64, *value.String) = .empty,
    /// The string of each symbol, made on first use.
    sym_strings: std.ArrayList(?*value.String) = .empty,
    /// Scratch memory of the compiler, kept from file to file.
    compile_scratch: Scratch,
    /// The last parse tree, whose buffers the next parse reuses.
    ast_reuse: @import("../syntax/ast.zig").Ast = .{},
    /// Shared IR nodes, made on the first compile.
    shared_ir: ?*SharedIr = null,
    /// The one empty list and the one empty set of this thread: nixpkgs
    /// makes the same empty values again and again.
    empty_list: ?*value.List = null,
    empty_attrs: ?*value.Attrs = null,
    /// Lint sites any fiber on this worker saw reported or silenced: a hit
    /// skips the shared lock, and a firing site is evaluated many times
    /// more than it is reported (`lint/report.zig`).
    lint_seen: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// `lint_mod.Where` of every file this worker classified, by its base.
    lint_where: std.AutoHashMapUnmanaged(u32, lint_mod.Where) = .empty,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) Local {
        return .{ .arena = .init(gpa), .compile_scratch = .init(gpa), .gpa = gpa };
    }

    noinline fn emptyList(l: *Local) error{OutOfMemory}!*value.List {
        const e = try l.arena.createWithTail(value.List, Cell, 0);
        e.* = .{ .len = 0 };
        if (census.enabled) l.arena.census.noteList(e);
        l.empty_list = e;
        return e;
    }

    noinline fn emptyAttrs(l: *Local) error{OutOfMemory}!*value.Attrs {
        const e = try l.arena.createWithTail(value.Attrs, value.Attr, 0);
        e.* = .{ .len = 0 };
        if (census.enabled) l.arena.census.noteAttrs(@ptrCast(e), .other, 0);
        l.empty_attrs = e;
        return e;
    }

    noinline fn sharedIr(l: *Local) error{OutOfMemory}!*SharedIr {
        const t = try l.gpa.create(SharedIr);
        t.* = .{};
        l.shared_ir = t;
        return t;
    }

    pub fn deinit(l: *Local) void {
        l.strings.deinit(l.gpa);
        l.sym_strings.deinit(l.gpa);
        l.lint_seen.deinit(l.gpa);
        l.lint_where.deinit(l.gpa);
        l.ast_reuse.deinit(l.gpa);
        if (l.shared_ir) |t| l.gpa.destroy(t);
        l.compile_scratch.deinit();
        l.arena.deinit();
    }
};

pub const Par = struct {
    /// The demand path: it prints, and it writes forced values into cells.
    is_main: bool = true,
    /// Several workers are running: thunks are claimed with a compare-and-swap.
    on: bool = false,
    /// The claimer id this evaluator puts into a blackhole; 0 is the main fiber.
    id: u32 = 0,
    /// A helper met an effect: its task is over, and nothing it computes
    /// from here on may be published.
    cancelled: bool = false,
};

gpa: std.mem.Allocator,
/// What the thread running this evaluator owns: see `Local`.
local: *Local,
interner: *Interner,
files: *Files,
s: WellKnown,
failure: ?Failure = null,
call_depth: u32 = 0,
/// Names visible at the root of every file, after lexical scopes and `with`.
globals: std.AutoHashMapUnmanaged(Sym, Value) = .empty,
io: std.Io,
config: Config,
/// The env every file's root expression is evaluated in; it has no slots.
root_env: *Env = undefined,
store_dir: []const u8 = "/nix/store",
stats: Stats = .{},
/// The error behind an internal `.failed` word.
pending: Error = error.EvalFailed,
/// Who runs this evaluator: the demand path, or a helper forcing ahead of it.
par: Par = .{},
/// The pool of a parallel run.
pool: ?*Pool = null,
/// The lints not `off` anywhere, one bit each: what `lintOn` tests, one
/// load and a branch. Follows `config.lints` (`setLints`).
lint_on: lint_mod.Mask = 0,
/// The fiber this evaluator runs on, in a parallel run.
fiber: ?*Pool.Fiber = null,

/// Where `trace` and warnings go; nothing is printed without one.
stderr: ?*std.Io.Writer = null,
/// Compare as Nix does, without the shortcut that two equal words are equal
/// unforced (tests check what the shortcut skips).
nix_eq: bool = false,
/// This fiber's shadow stack for `IETS_PROFILE`; null when the run does not
/// profile (`profile.zig`). Set it with `setProfile`.
prof: ?*profile.Stack = null,
/// The call depth past which `applyRaw` takes its slow path: the limit, or
/// 0 while profiling.
call_limit: u32 = max_call_depth,
/// What every worker's evaluator shares; see `Shared.zig`.
shared: *Shared,

pub const Stats = struct {
    thunks: u64 = 0,
    calls: u64 = 0,
    /// Time spent parsing and compiling.
    compile_ns: u64 = 0,
    /// The main thread's waits for thunks other threads hold.
    waits: u64 = 0,
    wait_ns: u64 = 0,
    /// A helper fiber's cells: forced, failed, and given up.
    forced: u64 = 0,
    failed: u64 = 0,
    cancelled: u64 = 0,
    parse_ns: u64 = 0,
    files: u64 = 0,
    /// Trees and texts made into a store path: Nix's `addToStore` and
    /// `addTextToStore` calls (`store_hooks.noteStoreAdd`).
    store_adds: u64 = 0,
    /// Arena bytes by object kind; `IETS_STATS=1` prints them.
    bytes: std.EnumArray(Cat, u64) = .initFill(0),

    pub const Cat = enum { env, thunk, lambda, attrs, update, list, string, string_bytes, ir };
};

inline fn count(ev: *Evaluator, cat: Stats.Cat, before: usize) void {
    ev.stats.bytes.getPtr(cat).* += ev.local.arena.used - before;
}

/// `count` for an object of known size: no reload of the arena's counter
/// just after the allocation stored it.
inline fn tally(ev: *Evaluator, cat: Stats.Cat, n: usize) void {
    ev.stats.bytes.getPtr(cat).* += std.mem.alignForward(usize, n, 8);
}

pub const SearchPathEntry = struct { prefix: []const u8, path: []const u8 };

/// Fixed before evaluation starts; nothing changes it after.
pub const Config = struct {
    pure: bool = false,
    system: []const u8 = "x86_64-linux",
    search_path: []const SearchPathEntry = &.{},
    home: []const u8 = "/",
    /// The current directory, for relative paths given on the command line.
    cwd: []const u8 = "/",
    /// Lint levels, scope and roots (docs/reference/lints.md).
    lints: *const lint_mod.Config = &lint_mod.default_config,
    /// The `parse-toml-timestamps` experimental feature (`fromTOML`).
    parse_toml_timestamps: bool = false,

    /// The directory a pure evaluation may read below, besides the store
    /// paths it made; none when null (store_hooks.zig:allowed).
    project_root: ?[]const u8 = null,
    /// The compiled-IR cache imports go through; null with `--no-cache`.
    ir_cache: ?*@import("../ir_cache.zig").IrCache = null,
    /// Keep every derivation's ATerm, so `readFile` of a `.drv` this
    /// evaluation made reads it. Only the tracing cache and `--dump-drvs`
    /// read it after evaluation, so `iets eval` turns it off without them; a
    /// producer of a `.drv` keeps it regardless.
    keep_aterm: bool = true,
    /// Record where each derivation was defined, for the build's names
    /// (provenance.zig). `iets eval` never builds, so it turns it off.
    keep_site: bool = true,
    /// `--dump-drvs DIR`: each derivation's ATerm is written to `DIR/<base>`
    /// as it is made.
    dump_dir: ?[]const u8 = null,
    /// The run's log, events and settings (`session.zig`); null for an
    /// evaluator a test makes on its own.
    session: ?*@import("../session.zig").Session = null,

    /// The input store fetched trees live in; null when there is no cache
    /// directory, and then nothing fetched can be kept.
    inputs: ?*@import("../treestore.zig").Store = null,
    /// What one download may cost, and whether any may happen (`IETS_OFFLINE`).
    fetch_limits: @import("../fetch/http.zig").Limits = .{},
    offline: bool = false,

    /// The tracing cache's recorder: every read of the outside world goes
    /// through it. Off unless the run has a cache entry to write.
    trace: @import("../trace.zig").Trace = .off,
};

pub fn init(gpa: std.mem.Allocator, io: std.Io, local: *Local, interner: *Interner, files: *Files, shared: *Shared, config: Config) !Evaluator {
    for (nix_static_symbols) |n| _ = try interner.intern(n);
    var s: WellKnown = undefined;
    inline for (@typeInfo(WellKnown).@"struct".field_names) |n| {
        @field(s, n) = try interner.intern(n);
    }
    var cfg = config;
    // a pure evaluation keeps the empty search path (eval.cc:EvalState), so
    // `-I` gives no `<name>` and `builtins.nixPath` is empty
    if (cfg.pure) cfg.search_path = &.{};
    return .{
        .gpa = gpa,
        .local = local,
        .interner = interner,
        .files = files,
        .s = s,
        .shared = shared,
        .io = io,
        .config = cfg,
        .lint_on = config.lints.mask(),
        .store_dir = @import("../store/path.zig").store_dir,
    };
}

/// The run's read-set recorder.
pub inline fn trace(ev: *const Evaluator) @import("../trace.zig").Trace {
    return ev.config.trace;
}

/// Replace the lint configuration, which `init` took from `config`.
pub fn setLints(ev: *Evaluator, cfg: *const lint_mod.Config) void {
    ev.config.lints = cfg;
    ev.lint_on = cfg.mask();
}

/// A helper's evaluator: this one's settings and shared tables, the
/// helper thread's `local`, and statistics of its own.
pub fn forkHelper(main: *const Evaluator, local: *Local, interner: *Interner, id: u32) Evaluator {
    var h = main.*;
    h.local = local;
    h.interner = interner;
    h.failure = null;
    h.call_depth = 0;
    h.stats = .{};
    h.pool = null;
    // a profile runs on one worker (settings.zig); a helper never samples
    h.prof = null;
    h.call_limit = max_call_depth;
    h.par = .{ .is_main = false, .on = true, .id = id };
    return h;
}

/// `deinit` for a helper, which shares the globals with the main evaluator.
pub fn deinitHelper(ev: *Evaluator) void {
    ev.clearFailure();
}

pub fn deinit(ev: *Evaluator) void {
    ev.clearFailure();
    ev.globals.deinit(ev.gpa);
}

/// An effect the program can see: a `trace`, a warning. A helper must not
/// print what the sequential run would print later, or never, so it gives
/// up its task and the demand path, which reaches this too, prints it.
pub fn effect(ev: *Evaluator, comptime fmt: []const u8, args: anytype) Error!void {
    if (!ev.par.is_main) {
        // Sticky: every publish this helper still makes becomes a reset.
        ev.par.cancelled = true;
        return ev.cancel();
    }
    lint_report.flush(ev);
    ev.log(fmt, args);
}

/// Whether lint `id` is on anywhere: the one check a hook pays while it is off.
pub inline fn lintOn(ev: *const Evaluator, id: lint_mod.LintId) bool {
    return ev.lint_on & lint_mod.bit(id) != 0;
}

/// Report a lint site (`lint/report.zig`); `fmt` is formatted only when
/// the site reports.
pub inline fn lint(ev: *Evaluator, id: lint_mod.LintId, pos: Pos, comptime fmt: []const u8, args: anytype) Error!void {
    if (!ev.lintOn(id)) return;
    return lint_report.site(ev, id, pos, null, null, fmt, args);
}

/// Unwind a helper's task: an error `tryEval` does not catch, which resets
/// every thunk the helper holds on the way out.
pub fn cancel(ev: *Evaluator) Error {
    @branchHint(.cold);
    return ev.fail(.cancelled, .none, "cancelled", .{});
}

/// A line on stderr: the session's log when there is one, which makes it a
/// record under internal-json and filters it as Nix filters stderr.
pub fn log(ev: *Evaluator, comptime fmt: []const u8, args: anytype) void {
    @branchHint(.cold);
    if (ev.config.session) |s| {
        const text = std.fmt.allocPrint(ev.gpa, fmt, args) catch return;
        defer ev.gpa.free(text);
        return s.log.textLine(text);
    }
    const w = ev.stderr orelse return;
    w.print(fmt ++ "\n", args) catch {};
    w.flush() catch {};
}

/// `IETS_STATS=2`: the census of this worker's arena, which is about
/// duplicates inside one arena, or how to get it.
pub fn printCensus(ev: *Evaluator) void {
    if (!census.enabled) return ev.log("census: build with -Dstats2=true", .{});
    var out: std.Io.Writer.Allocating = .init(ev.gpa);
    defer out.deinit();
    ev.local.arena.census.report(&out.writer) catch return;
    if (ev.config.session) |s| return s.log.err(out.written());
    const w = ev.stderr orelse return;
    w.writeAll(out.written()) catch {};
    w.flush() catch {};
}

// Errors.

/// Record an error and return `error.EvalFailed`.
pub fn fail(ev: *Evaluator, kind: ErrorKind, pos: Pos, comptime fmt: []const u8, args: anytype) Error {
    @branchHint(.cold);
    ev.clearFailure();
    const msg = try std.fmt.allocPrint(ev.gpa, fmt, args);
    ev.failure = .{ .kind = kind, .msg = msg, .pos = pos };
    return error.EvalFailed;
}

/// `fail`, with the fix for it as the error's hint.
pub fn failHint(ev: *Evaluator, kind: ErrorKind, pos: Pos, hint: []const u8, comptime fmt: []const u8, args: anytype) Error {
    @branchHint(.cold);
    const e = ev.fail(kind, pos, fmt, args);
    if (ev.failure) |*f| f.hint = try ev.gpa.dupe(u8, hint);
    return e;
}

/// Add a line to the trace of the error in flight, and pass the error on.
pub fn addTrace(ev: *Evaluator, err: Error, pos: Pos, comptime fmt: []const u8, args: anytype) Error {
    @branchHint(.cold);
    if (err != error.EvalFailed) return err;
    const f = &(ev.failure orelse return err);
    const msg = try std.fmt.allocPrint(ev.gpa, fmt, args);
    // Not `errdefer`: this function always returns an error.
    f.trace.append(ev.gpa, .{ .pos = pos, .msg = msg }) catch {
        ev.gpa.free(msg);
        return error.OutOfMemory;
    };
    return err;
}

pub fn clearFailure(ev: *Evaluator) void {
    const f = &(ev.failure orelse return);
    ev.gpa.free(f.msg);
    for (f.trace.items) |t| ev.gpa.free(t.msg);
    f.trace.deinit(ev.gpa);
    if (f.hint) |h| ev.gpa.free(h);
    ev.failure = null;
}

pub fn failureKind(ev: *const Evaluator) ?ErrorKind {
    return if (ev.failure) |f| f.kind else null;
}

/// Mirrors eval.cc's type errors: "expected a set but found an integer: 1".
pub fn typeError(ev: *Evaluator, expected: []const u8, got: Value, pos: Pos, ctx: []const u8) Error {
    @branchHint(.cold);
    const e = ev.fail(.type, pos, "expected {s} but found {s}: {f}", .{ expected, got.typeOf().show(), print.short(ev, got) });
    if (ctx.len == 0) return e;
    return ev.addTrace(e, pos, "{s}", .{ctx});
}

/// A helper's stack is smaller than the demand path's: near its end the
/// helper gives up, and the demand path computes the value. Every deep
/// recursion calls this: calls, the deep walk, the JSON reader and writer.
pub inline fn checkStack(ev: *Evaluator) Error!void {
    if (!ev.par.is_main) if (ev.fiber) |f| if (@frameAddress() < f.stackLimit() or f.cancel.load(.monotonic)) return ev.cancel();
}

fn enterCall(ev: *Evaluator, pos: Pos) Error!void {
    try ev.checkStack();
    if (ev.call_depth >= max_call_depth)
        return ev.fail(.stack_overflow, pos, "stack overflow; max-call-depth exceeded", .{});
    ev.call_depth += 1;
}

// Values.

pub fn mkInt(ev: *Evaluator, i: i64) Error!Value {
    if (Value.fitsImm(i)) return .immInt(i);
    const o = try ev.local.arena.create(value.IntObj);
    o.* = .{ .val = i };
    return .fromPtr(.ptr, o);
}

pub fn mkFloat(ev: *Evaluator, f: f64) Error!Value {
    const o = try ev.local.arena.create(value.FloatObj);
    o.* = .{ .val = f };
    return .fromPtr(.ptr, o);
}

/// A string over bytes that already live as long as the run.
pub fn mkStringStatic(ev: *Evaluator, bytes: []const u8, ctx: []const Ctx) Error!Value {
    ev.tally(.string, @sizeOf(value.String));
    const o = try ev.local.arena.create(value.String);
    o.* = .{ .ptr = bytes.ptr, .len = bytes.len, .ctx_ptr = ctx.ptr, .ctx_len = ctx.len };
    if (census.enabled) {
        ev.local.arena.census.noteString(o, bytes, ctx.len * @sizeOf(Ctx));
        ev.local.arena.census.noteCtx(ctx);
    }
    return .fromPtr(.ptr, o);
}

/// The shared context-free string with these bytes, made if it is new.
fn sharedString(ev: *Evaluator, bytes: []const u8) Error!*value.String {
    const h = std.hash.Wyhash.hash(0, bytes);
    const gop = try ev.local.strings.getOrPut(ev.gpa, h);
    if (gop.found_existing and bytes_.eql(gop.value_ptr.*.bytes(), bytes)) return gop.value_ptr.*;
    const b = ev.local.arena.dupe(u8, bytes) catch |e| {
        if (!gop.found_existing) ev.local.strings.removeByPtr(gop.key_ptr);
        return e;
    };
    ev.tally(.string_bytes, bytes.len);
    const str = (try ev.mkStringStatic(b, &.{})).asUnmarked(value.String);
    if (!gop.found_existing) gop.value_ptr.* = str;
    return str;
}

pub fn mkString(ev: *Evaluator, bytes: []const u8) Error!Value {
    return .fromPtr(.ptr, try ev.sharedString(bytes));
}

/// A string with context; `ctx` need not be sorted or unique. The bytes are
/// shared with the context-free string of the same text.
pub fn mkStringCtx(ev: *Evaluator, bytes: []const u8, ctx: []const Ctx) Error!Value {
    const shared = try ev.sharedString(bytes);
    if (ctx.len == 0) return .fromPtr(.ptr, shared);
    return ev.mkStringStatic(shared.bytes(), try ev.ctxToArena(ctx));
}

/// Sort and deduplicate a context into the arena.
pub fn ctxToArena(ev: *Evaluator, ctx: []const Ctx) Error![]const Ctx {
    if (ctx.len == 0) return &.{};
    const out = try ev.local.arena.dupe(Ctx, ctx);
    std.sort.pdq(Ctx, out, {}, Ctx.lessThan);
    var n: usize = 1;
    for (out[1..]) |c| {
        if (c.order(out[n - 1]) == .eq) continue;
        out[n] = c;
        n += 1;
    }
    return out[0..n];
}

pub fn mkPath(ev: *Evaluator, bytes: []const u8) Error!Value {
    const b = try ev.local.arena.dupe(u8, bytes);
    const o = try ev.local.arena.create(value.Path);
    o.* = .{ .ptr = b.ptr, .len = b.len };
    return .fromPtr(.ptr, o);
}

pub fn allocList(ev: *Evaluator, n: usize) Error!*value.List {
    if (n == 0) return ev.local.empty_list orelse ev.local.emptyList();
    ev.tally(.list, @sizeOf(value.List) + n * @sizeOf(Cell));
    const l = try ev.local.arena.createWithTail(value.List, Cell, n);
    l.* = .{ .len = @intCast(n) };
    if (census.enabled) ev.local.arena.census.noteList(l);
    return l;
}

pub fn mkList(ev: *Evaluator, items: []const Value) Error!Value {
    const l = try ev.allocList(items.len);
    for (l.raw(), items) |*c, v| c.* = .init(v);
    return .fromPtr(.ptr, l);
}

pub fn allocAttrs(ev: *Evaluator, n: usize) Error!*value.Attrs {
    if (n == 0) return ev.local.empty_attrs orelse ev.local.emptyAttrs();
    ev.tally(.attrs, @sizeOf(value.Attrs) + n * @sizeOf(value.Attr));
    const a = try ev.local.arena.createWithTail(value.Attrs, value.Attr, n);
    a.* = .{ .len = @intCast(n) };
    if (census.enabled) ev.local.arena.census.noteAttrs(@ptrCast(a), .other, n);
    return a;
}

/// A set from attributes already sorted by symbol and unique.
pub fn mkAttrsSorted(ev: *Evaluator, entries: []const value.Attr) Error!Value {
    const a = try ev.allocAttrs(entries.len);
    @memcpy(a.raw(), entries);
    return .fromPtr(.ptr, a);
}

/// Census: the producer of a set `allocAttrs` just made.
pub inline fn censusOrigin(ev: *Evaluator, a: *value.Attrs, o: census.Origin) void {
    if (census.enabled) ev.local.arena.census.retag(a, o);
}

/// `mkAttrsSorted` of a producer the census tells apart.
pub inline fn mkAttrsSortedAs(ev: *Evaluator, entries: []const value.Attr, o: census.Origin) Error!Value {
    if (!census.enabled) return ev.mkAttrsSorted(entries);
    const r = try ev.mkAttrsSorted(entries);
    ev.censusOrigin(r.as(value.Attrs), o);
    return r;
}

/// A set from attributes in any order; a duplicate name is an error at `pos`.
pub fn mkAttrs(ev: *Evaluator, entries: []value.Attr, pos: Pos) Error!Value {
    std.sort.pdq(value.Attr, entries, {}, attrLess);
    for (1..@max(entries.len, 1)) |i| {
        if (entries[i].sym == entries[i - 1].sym)
            return ev.fail(.eval, entries[i].pos, "attribute '{s}' already defined at {f}", .{ ev.interner.name(entries[i].sym), ev.files.at(entries[i - 1].pos) });
    }
    _ = pos;
    return ev.mkAttrsSorted(entries);
}

fn attrLess(_: void, a: value.Attr, b: value.Attr) bool {
    return @backingInt(a.sym) < @backingInt(b.sym);
}

pub fn emptyAttrs(ev: *Evaluator) Error!Value {
    return ev.mkAttrsSorted(&.{});
}

pub fn sym(ev: *Evaluator, name: []const u8) Error!Sym {
    return ev.interner.intern(name);
}

pub fn symString(ev: *Evaluator, s: Sym) Error!Value {
    const i = s.index();
    if (i < ev.local.sym_strings.items.len) if (ev.local.sym_strings.items[i]) |str| return .fromPtr(.ptr, str);
    if (i >= ev.local.sym_strings.items.len) try ev.local.sym_strings.appendNTimes(ev.gpa, null, i + 1 - ev.local.sym_strings.items.len);
    const v = try ev.mkStringStatic(ev.interner.name(s), &.{});
    v.asUnmarked(value.String).cacheSym(s);
    ev.local.sym_strings.items[i] = v.asUnmarked(value.String);
    return v;
}

pub fn mkThunk(ev: *Evaluator, env: *Env, code: ir.Ref) Error!Value {
    ev.tally(.thunk, @sizeOf(value.Thunk));
    ev.stats.thunks += 1;
    const t = try ev.local.arena.create(value.Thunk);
    t.* = .{ .code = .{ .raw = @intFromPtr(code) }, .state = .{ .raw = @intFromPtr(env) } };
    if (census.enabled) {
        env.markCaptured();
        ev.local.arena.census.noteThunkCreated(@intFromPtr(t) | @backingInt(value.Tag.thunk));
    }
    return .fromPtr(.thunk, t);
}

/// A suspended `f x`.
pub fn mkThunkApp(ev: *Evaluator, f: Value, x: Value) Error!Value {
    ev.tally(.thunk, @sizeOf(value.ThunkApp));
    ev.stats.thunks += 1;
    const t = try ev.local.arena.create(value.ThunkApp);
    t.* = .{ .code = .init(f), .state = .init(x) };
    if (census.enabled) ev.local.arena.census.noteThunkCreated(@intFromPtr(t) | @backingInt(value.Tag.thunk_app));
    return .fromPtr(.thunk_app, t);
}

pub fn mkLambda(ev: *Evaluator, env: *Env, lam: *const ir.Lambda) Error!Value {
    ev.tally(.lambda, @sizeOf(value.Lambda));
    const l = try ev.local.arena.create(value.Lambda);
    l.* = .{ .env = env, .lam = lam };
    if (census.enabled) {
        env.markCaptured();
        ev.local.arena.census.lambda_closed += @intFromBool(lam.closed);
    }
    return .fromPtr(.lambda, l);
}

/// An IR node in the arena. A `local` or `constant` is made once per
/// thread and shared: a third of compiled nodes repeat one, and IR never
/// changes once built.
pub inline fn irNode(ev: *Evaluator, node: ir.Ir) Error!ir.Ref {
    const l = ev.local;
    const t = l.shared_ir orelse try l.sharedIr();
    switch (node) {
        .local => |x| if (x.depth < 16 and x.idx < 64) {
            const slot = &t.locals[x.depth][x.idx];
            if (slot.*) |p| return p;
            const p = try l.arena.create(ir.Ir);
            p.* = node;
            slot.* = p;
            return p;
        },
        .constant => |v| {
            const slot = &t.consts[(v.bits() *% 0x9E3779B97F4A7C15) >> 52];
            if (slot.node) |p| if (slot.word == v.bits()) return p;
            const p = try l.arena.create(ir.Ir);
            p.* = node;
            slot.* = .{ .word = v.bits(), .node = p };
            return p;
        },
        else => {},
    }
    const p = try l.arena.create(ir.Ir);
    p.* = node;
    return p;
}

pub fn allocEnv(ev: *Evaluator, up: ?*Env, n: usize) Error!*Env {
    ev.tally(.env, @sizeOf(Env) + n * @sizeOf(Cell));
    const e = try ev.local.arena.createWithTail(Env, Cell, n);
    e.* = .{ .up = up };
    for (e.slots()[0..n]) |*c| c.* = .init(.empty);
    if (census.enabled) {
        if (up) |u| u.markCaptured();
        ev.local.arena.census.noteEnv(e, n);
    }
    return e;
}

/// `{ file, line, column }` for a position, or null when it has none.
pub fn mkPosAttrs(ev: *Evaluator, pos: Pos) Error!Value {
    const loc = ev.files.locate(pos) orelse return .null;
    var entries = [_]value.Attr{
        .{ .sym = ev.s.file, .pos = .none, .cell = .init(try ev.mkStringStatic(loc.file.path, &.{})) },
        .{ .sym = ev.s.line, .pos = .none, .cell = .init(try ev.mkInt(loc.line)) },
        .{ .sym = ev.s.column, .pos = .none, .cell = .init(try ev.mkInt(loc.column)) },
    };
    return ev.mkAttrs(&entries, .none);
}

// Forcing.

pub inline fn force(ev: *Evaluator, v: Value) Error!Value {
    if (!v.isThunk()) return v;
    return ev.forceThunk(v);
}

/// Force the value in a cell and write the result back, so later readers
/// skip the thunk.
pub inline fn forceCell(ev: *Evaluator, c: *Cell) Error!Value {
    const v = c.get();
    if (!v.isThunk()) return v;
    const r = try ev.forceThunk(v);
    // Only the demand path unboxes a cell: one that holds a value is one the
    // program asked for, which `==` and the printers read.
    if (ev.par.is_main) c.set(r);
    return r;
}

fn forceThunk(ev: *Evaluator, v: Value) Error!Value {
    const r = ev.forceThunkRaw(v);
    if (r == .failed) return ev.pending;
    return r;
}

fn forceThunkRaw(ev: *Evaluator, v: Value) Value {
    if (ev.par.on) return ev.forceThunkShared(v);
    const cells = v.thunkCells();
    const st = cells.state.get();
    switch (st) {
        .empty => return cells.code.get(),
        .blackhole => return ev.stash(ev.fail(.infinite_recursion, ev.thunkPos(v), "infinite recursion encountered", .{})),
        else => {},
    }
    cells.state.set(.blackhole);
    if (census.enabled) {
        const c = &ev.local.arena.census;
        c.forced[
            switch (v.tag()) {
                .thunk => 0,
                .thunk_app => 1,
                else => 3,
            }
        ] += 1;
        c.noteThunkForced(v.bits());
    }
    const r = ev.runThunk(v, cells.code, st);
    if (r == .failed) {
        cells.state.set(st);
        return r;
    }
    std.debug.assert(!r.isThunk());
    cells.code.set(r);
    cells.state.set(.empty);
    return r;
}

/// `forceThunkRaw` with other fibers about: the claim protocol of
/// docs/explanation/evaluation.md. The state cell is the synchronisation
/// word. A plain load comes first, since most forces find a thunk another
/// fiber already evaluated and the cache line can stay shared; only a
/// payload is claimed, with a compare-and-swap into this fiber's blackhole.
/// The claimer publishes `empty` (demand) or `speculated` (a helper), or
/// puts the payload back when it fails.
fn forceThunkShared(ev: *Evaluator, v: Value) Value {
    const cells = v.thunkCells();
    const state: *std.atomic.Value(u64) = @ptrCast(&cells.state.raw);
    const pool = ev.pool.?;
    const f = ev.fiber.?;
    const key = @intFromPtr(state);
    var st = cells.state.get();
    while (true) {
        switch (st) {
            .empty => return cells.code.get(),
            .speculated => {
                // The first demand of a helper's result makes it the program's.
                if (ev.par.is_main) _ = state.cmpxchgStrong(st.bits(), Value.empty.bits(), .acq_rel, .acquire);
                return cells.code.get();
            },
            .speculated_fx => {
                // ... and so are the effects parked on it.
                const r = cells.code.get();
                if (ev.par.is_main) _ = state.cmpxchgStrong(st.bits(), Value.empty.bits(), .acq_rel, .acquire);
                effects.readSpeculated(ev, key);
                return r;
            },
            else => {},
        }
        // A thunk that failed for another helper is not worth starting
        // again: the demand path evaluates it and reports. Inside the loop,
        // so a waiter the failure woke stops instead of claiming the reset.
        if (!ev.par.is_main and pool.isFailed(key)) return ev.stash(ev.cancel());
        if (st.isBlackhole()) {
            if (st.claimer() == ev.par.id)
                return ev.stash(ev.fail(.infinite_recursion, ev.thunkPos(v), "infinite recursion encountered", .{}));
            if (!pool.wait(f, state, st)) return ev.stash(ev.cancel());
            st = cells.state.get();
            continue;
        }
        if (state.cmpxchgWeak(st.bits(), Value.blackholeOf(ev.par.id).bits(), .acq_rel, .acquire)) |now| {
            st = @fromBackingInt(@intCast(now));
            continue;
        }
        break;
    }
    if (!ev.par.is_main and (ev.par.cancelled or f.cancel.load(.monotonic) or @frameAddress() < f.stackLimit())) {
        ev.publish(state, st);
        return ev.stash(ev.cancel());
    }
    // a helper's effects from here on are this thunk's, in their order
    const spec: u32 = @intFromBool(!ev.par.is_main);
    const mark = f.effects.log.items.len;
    f.effects.frames += spec;
    const r = ev.runThunk(v, cells.code, st);
    f.effects.frames -= spec;
    if (r == .failed) {
        const kind = ev.failureKind();
        if (!ev.par.is_main and kind != .cancelled) pool.noteFailed(key);
        // a `tryEval` above may catch the error and keep its value: the
        // thunk that forced this one carries what it did
        if (ev.par.cancelled or kind == .cancelled or f.effects.frames == 0) effects.truncate(ev, mark);
        ev.publish(state, st);
        return r;
    }
    std.debug.assert(!r.isThunk());
    if (ev.par.cancelled) {
        // An effect below gave up the task: whatever this computed must not
        // reach a shared thunk.
        effects.truncate(ev, mark);
        ev.publish(state, st);
        return ev.stash(ev.cancel());
    }
    if (f.effects.log.items.len > mark) return ev.publishWithEffects(v, state, st, key, mark, r);
    cells.code.set(r);
    ev.publish(state, if (ev.par.is_main) .empty else .speculated);
    return r;
}

/// A helper's thunk whose evaluation made effects: they wait on it until
/// the demand path takes the value.
noinline fn publishWithEffects(ev: *Evaluator, v: Value, state: *std.atomic.Value(u64), st: Value, key: usize, mark: usize, r: Value) Value {
    if (v.tag() == .thunk_map) {
        // The value of a `mapAttrs` entry goes into the set's own cell,
        // where a read takes it without its effects: the entry stays
        // unforced, and the thunk that forced it carries them.
        if (ev.fiber.?.effects.frames == 0) effects.truncate(ev, mark);
        ev.publish(state, st);
        return r;
    }
    effects.park(ev, key, mark);
    if (ev.par.cancelled) {
        // the effects found no room: the thunk goes back unforced
        ev.publish(state, st);
        return ev.stash(ev.cancel());
    }
    v.thunkCells().code.set(r);
    ev.publish(state, .speculated_fx);
    return r;
}

/// Replace this fiber's claim with `next`, and wake whoever waits on it.
fn publish(ev: *Evaluator, state: *std.atomic.Value(u64), next: Value) void {
    const old: Value = @fromBackingInt(@intCast(state.swap(next.bits(), .acq_rel)));
    if (old.hasWaiters()) ev.pool.?.wakeWaiters(ev.fiber.?.worker, state);
}

// Helper tasks: what an idle worker runs of the cells a walk offered.

pub const CellState = union(enum) { ready: Value, busy, unclaimed };

/// What a cell holds, as a helper may read it: a forced value (taking a
/// helper's result, on the demand path), a thunk someone holds, or one no
/// one has started.
pub fn takeCell(ev: *Evaluator, c: *Cell) CellState {
    const v = c.get();
    if (!v.isThunk()) return .{ .ready = v };
    const cells = v.thunkCells();
    const st = cells.state.get();
    if (st.isBlackhole()) return .busy;
    if (st != .empty and st != .speculated and st != .speculated_fx) return .unclaimed;
    const r = cells.code.get();
    if (st == .speculated_fx) effects.readSpeculated(ev, @intFromPtr(&cells.state.raw));
    if (ev.par.is_main) {
        if (st != .empty) cells.state.set(.empty);
        c.set(r);
    }
    return .{ .ready = r };
}

fn cellState(c: *Cell) CellState {
    const v = c.get();
    if (!v.isThunk()) return .{ .ready = v };
    const st = v.thunkCells().state.get();
    if (st.isBlackhole()) return .busy;
    if (st != .empty and st != .speculated and st != .speculated_fx) return .unclaimed;
    return .{ .ready = v.thunkCells().code.get() };
}

/// Run a helper task; a failure or cancel ends it quietly.
pub fn runTask(ev: *Evaluator, t: Pool.Task) void {
    if (t.kind == .job) {
        const jobs: *Jobs = @ptrFromInt(@backingInt(t.obj));
        jobs.runOne(ev, t.start);
        jobs.release(ev.gpa);
        return;
    }
    if (t.kind == .prefetch) {
        if (ev.shared.prefetch) |p| p.f(p.ctx, ev, t.obj.as(value.Attrs), t.start, t.start + t.len);
        ev.clearFailure();
        effects.truncate(ev, 0);
        return;
    }
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(ev.gpa);
    for (t.start..t.start + t.len) |i| {
        const c = t.cell(i);
        const go = switch (t.kind) {
            .list_whnf, .attrs_whnf => ev.rangeStep(c, false, &seen),
            .list_deep, .attrs_deep => ev.rangeStep(c, true, &seen),
            .list_coerce, .attrs_coerce => ev.coerceStep(c, 0),
            .job, .prefetch => unreachable,
        };
        if (!go) break;
    }
    ev.clearFailure();
    effects.truncate(ev, 0);
}

/// Jobs that run on whichever workers are free, the caller among them:
/// the parser's chunks, the compiler's huge sets. Each job's state word
/// follows the claim protocol of a thunk (`.null` unclaimed, the
/// claimer's blackhole, `.empty` done). Counted: a queued task may be
/// taken after the caller has run its job and returned. A job never
/// parks, so the caller waits by spinning: it stays on its worker, whose
/// interner and compile scratch its own work goes on using.
pub const Jobs = struct {
    n: u32,
    ctx: *anyopaque,
    job: *const fn (*anyopaque, u32, *Evaluator) void,
    refs: std.atomic.Value(u32),
    states: [max]std.atomic.Value(u64),

    pub const max = 64;

    fn runOne(j: *Jobs, ev: *Evaluator, i: u32) void {
        const st = &j.states[i];
        if (st.cmpxchgStrong(Value.null.bits(), Value.blackholeOf(ev.par.id).bits(), .acq_rel, .acquire) != null) return;
        j.job(j.ctx, i, ev);
        st.store(Value.empty.bits(), .release);
    }

    fn release(j: *Jobs, gpa: std.mem.Allocator) void {
        if (j.refs.fetchSub(1, .acq_rel) == 1) gpa.destroy(j);
    }
};

/// Run `job(ctx, i, ev)` for every `i < n`, with `ev` the evaluator of
/// whichever fiber runs it, on this worker and idle ones.
pub fn runJobs(ev: *Evaluator, n: u32, ctx: *anyopaque, job: *const fn (*anyopaque, u32, *Evaluator) void) void {
    const pool = ev.pool;
    const f = ev.fiber;
    if (pool == null or f == null or n > Jobs.max) {
        for (0..n) |i| job(ctx, @intCast(i), ev);
        return;
    }
    const j = ev.gpa.create(Jobs) catch {
        for (0..n) |i| job(ctx, @intCast(i), ev);
        return;
    };
    j.* = .{ .n = n, .ctx = ctx, .job = job, .refs = .init(1), .states = undefined };
    for (j.states[0..n]) |*st| st.* = .init(Value.null.bits());
    // The last job first: the deques are LIFO for their owner, and this
    // fiber takes the first ones itself.
    var i = n;
    while (i > 1) {
        i -= 1;
        _ = j.refs.fetchAdd(1, .monotonic);
        if (!pool.?.submit(f.?.worker, .{ .kind = .job, .obj = @fromBackingInt(@intFromPtr(j)), .start = i, .len = 1 }))
            _ = j.refs.fetchSub(1, .monotonic);
    }
    for (0..n) |k| j.runOne(ev, @intCast(k));
    for (j.states[0..n]) |*st| while (st.load(.acquire) != Value.empty.bits()) std.atomic.spinLoopHint();
    j.release(ev.gpa);
}

const ParserJob = struct {
    ctx: *anyopaque,
    job: *const fn (*anyopaque, u32, *Interner) void,

    fn run(ctx: *anyopaque, i: u32, ev: *Evaluator) void {
        const pj: *ParserJob = @ptrCast(@alignCast(ctx));
        pj.job(pj.ctx, i, ev.interner);
    }
};

fn parserRun(ctx: *anyopaque, n: u32, job_ctx: *anyopaque, job: *const fn (*anyopaque, u32, *Interner) void) *Interner {
    const ev: *Evaluator = @ptrCast(@alignCast(ctx));
    var pj: ParserJob = .{ .ctx = job_ctx, .job = job };
    ev.runJobs(n, &pj, ParserJob.run);
    return ev.interner;
}

/// The parser's view of this evaluator's workers; null without a pool.
pub fn parallel(ev: *Evaluator) ?@import("../syntax/parser.zig").Parallel {
    const pool = ev.pool orelse return null;
    return .{ .ctx = ev, .workers = @intCast(pool.workers.len), .run = parserRun };
}

pub fn bailRequested(ev: *Evaluator) bool {
    if (ev.par.is_main) return false;
    return ev.par.cancelled or ev.fiber.?.cancel.load(.monotonic);
}

/// Force one cell of a range task, skipping one someone else holds.
/// False when the task should stop.
fn rangeStep(ev: *Evaluator, c: *Cell, deep: bool, seen: *std.AutoHashMapUnmanaged(u64, void)) bool {
    if (ev.bailRequested()) return false;
    const v = switch (ev.takeCell(c)) {
        .busy => return true,
        .ready => |r| if (deep) r else return true,
        .unclaimed => ev.forceCell(c) catch return false,
    };
    if (deep) ev.forceDeepInner(v, seen, false) catch return false;
    return true;
}

fn coerceStep(ev: *Evaluator, c: *Cell, depth: u32) bool {
    const v = switch (ev.takeCell(c)) {
        .busy => return true,
        .ready => |r| r,
        .unclaimed => ev.forceCell(c) catch return false,
    };
    return ev.coerceWalk(v, depth + 1);
}

/// A helper's walk of a forced value, shaped like a coercion to string. It
/// never waits on a busy cell. False when the task should stop.
fn coerceWalk(ev: *Evaluator, v: Value, depth: u32) bool {
    if (depth > 64 or ev.bailRequested()) return depth <= 64;
    switch (v.view()) {
        .list => |l| {
            ev.fanout(.list_coerce, v, 0, l.len, coerce_batch);
            for (l.cells()) |*c| if (!ev.coerceStep(c, depth)) return false;
        },
        .attrs => |a| {
            if (a.get(ev.s.__toString) != null) return true;
            if (a.get(ev.s.outPath)) |o| return ev.coerceStep(&o.cell, depth);
            ev.fanout(.attrs_coerce, .fromPtr(.ptr, a), 0, a.len, coerce_batch);
            for (a.attrs()) |*at| if (!ev.coerceStep(&at.cell, depth)) return false;
        },
        else => {},
    }
    return true;
}

pub const batch = 16;
const coerce_batch = 4;
const min_fanout = 4;

/// Submit cells `lo..hi` of `obj` as range tasks of `n` cells on this
/// fiber's worker lane; only batches holding a cell no one has started.
pub fn fanout(ev: *Evaluator, kind: Pool.Task.Kind, obj: Value, lo: u32, hi: u32, n: u32) void {
    const pool = ev.pool orelse return;
    const f = ev.fiber orelse return;
    if (hi - lo < min_fanout) return;
    var t: Pool.Task = .{ .kind = kind, .obj = obj, .start = lo, .len = 0 };
    while (t.start < hi) : (t.start += t.len) {
        t.len = @min(n, hi - t.start);
        const worth = for (t.start..t.start + t.len) |i| {
            if (cellState(t.cell(i)) == .unclaimed) break true;
        } else false;
        if (worth and !pool.submit(f.worker, t)) return;
    }
}

/// A list a strict builtin is about to walk, elements to WHNF.
pub inline fn offerList(ev: *Evaluator, l: *value.List) void {
    if (ev.pool != null) ev.fanout(.list_whnf, .fromPtr(.ptr, l), 0, l.len, batch);
}

/// A list whose elements are about to be coerced to strings.
pub inline fn offerListCoerce(ev: *Evaluator, l: *value.List) void {
    if (ev.pool != null) ev.fanout(.list_coerce, .fromPtr(.ptr, l), 0, l.len, coerce_batch);
}

/// A set whose values are about to be coerced: `derivationStrict`, JSON.
pub inline fn offerAttrsCoerce(ev: *Evaluator, a: *value.Attrs) void {
    if (ev.pool != null) ev.fanout(.attrs_coerce, .fromPtr(.ptr, a), 0, a.len, coerce_batch);
}

pub inline fn offerListDeep(ev: *Evaluator, l: *value.List) void {
    if (ev.pool != null) ev.fanout(.list_deep, .fromPtr(.ptr, l), 0, l.len, batch);
}

pub inline fn offerAttrsDeep(ev: *Evaluator, a: *value.Attrs) void {
    if (ev.pool != null) ev.fanout(.attrs_deep, .fromPtr(.ptr, a), 0, a.len, batch);
}

fn runThunk(ev: *Evaluator, v: Value, code: *Cell, st: Value) Value {
    return switch (v.tag()) {
        .thunk => ev.evalRaw(@ptrFromInt(st.bits()), @ptrFromInt(code.raw)),
        .thunk_app => ev.applyRaw(code.get(), &.{st}, .none),
        .thunk_map => {
            const d, const i = v.mapDesc();
            const at = &d.src.raw()[i];
            const name = ev.symString(at.sym) catch |e| return ev.stash(e);
            return ev.applyRaw(d.f, &.{ name, at.cell.get() }, .none);
        },
        else => unreachable,
    };
}

fn thunkPos(_: *Evaluator, v: Value) Pos {
    if (v.tag() != .thunk) return .none;
    const code: ir.Ref = @ptrFromInt(v.untagged(value.Thunk).code.raw);
    return code.pos();
}

/// `mapAttrs f a`: entries that are map words, no thunk objects.
pub fn mapAttrs(ev: *Evaluator, f: Value, a: *value.Attrs) Error!Value {
    const out = try ev.allocAttrs(a.len);
    ev.censusOrigin(out, .map_attrs);
    if (a.len > value.MapDesc.max_entries) {
        for (out.raw(), a.attrs()) |*o, at| o.* = .{ .sym = at.sym, .pos = at.pos, .cell = .init(try ev.mkThunkApp(try ev.mkThunkApp(f, try ev.symString(at.sym)), at.cell.get())) };
        return .fromPtr(.ptr, out);
    }
    const before = ev.local.arena.used;
    const d = try ev.local.arena.createWithTail(value.MapDesc, Cell, a.len);
    ev.count(.thunk, before);
    d.* = .{ .f = f, .src = a, .out = out };
    for (out.raw(), a.raw(), 0..) |*o, at, i| {
        o.* = .{ .sym = at.sym, .pos = at.pos, .cell = .init(Value.mapEntry(d, i)) };
        d.states()[i] = .init(.null);
    }
    return .fromPtr(.ptr, out);
}

pub fn forceDeep(ev: *Evaluator, v: Value) Error!Value {
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(ev.gpa);
    const r = try ev.force(v);
    try ev.forceDeepInner(r, &seen, true);
    return r;
}

/// A value reached twice is walked once, so a cyclic structure terminates.
/// `demand`: wait on busy cells, after doing every unclaimed one first;
/// otherwise, as a helper, skip them.
fn forceDeepInner(ev: *Evaluator, v: Value, seen: *std.AutoHashMapUnmanaged(u64, void), demand: bool) Error!void {
    try ev.checkStack();
    switch (v.view()) {
        .attrs => |a| {
            if ((try seen.getOrPut(ev.gpa, v.bits())).found_existing) return;
            ev.offerAttrsDeep(a);
            return ev.walk(value.Attr, a.attrs(), seen, demand);
        },
        .list => |l| {
            if ((try seen.getOrPut(ev.gpa, v.bits())).found_existing) return;
            ev.offerListDeep(l);
            return ev.walk(Cell, l.cells(), seen, demand);
        },
        else => {},
    }
}

inline fn itemCell(comptime T: type, x: *T) *Cell {
    return if (T == Cell) x else &x.cell;
}

fn walkTrace(ev: *Evaluator, comptime T: type, x: *T, e: Error) Error {
    if (T == Cell) return e;
    return ev.addTrace(e, x.pos, "while evaluating the attribute '{s}'", .{ev.interner.nameStr(x.sym)});
}

/// Walk the cells of `items`. Without `demand`, busy cells are skipped.
/// With it, the walk goes in order up to the first busy cell, does the
/// cells after it as a helper would, and then takes every cell from the
/// busy one on, in order. The cells done ahead are speculated, so their
/// effects run where the sequential run has them, and the first error in
/// sequential order is the one reported.
fn walk(ev: *Evaluator, comptime T: type, items: []T, seen: *std.AutoHashMapUnmanaged(u64, void), demand: bool) Error!void {
    if (!ev.par.on) {
        for (items) |*x| {
            const r = ev.forceCell(itemCell(T, x)) catch |e| return ev.walkTrace(T, x, e);
            try ev.forceDeepInner(r, seen, demand);
        }
        return;
    }
    var busy = items.len;
    for (items, 0..) |*x, i| {
        const c = itemCell(T, x);
        const r = switch (ev.takeCell(c)) {
            .busy => if (demand) {
                busy = i;
                break;
            } else continue,
            .ready => |r| r,
            .unclaimed => blk: {
                if (!demand and ev.bailRequested()) return ev.cancel();
                break :blk ev.forceCell(c) catch |e| return if (demand) ev.walkTrace(T, x, e) else e;
            },
        };
        ev.forceDeepInner(r, seen, demand) catch |e| return if (demand) ev.walkTrace(T, x, e) else e;
    }
    if (busy + 1 < items.len) ev.ahead(T, items[busy + 1 ..]);
    if (busy < items.len) for (items[busy..]) |*x| {
        const c = itemCell(T, x);
        const r = switch (ev.takeCell(c)) {
            .ready => |r| r,
            else => ev.forceCell(c) catch |e| return ev.walkTrace(T, x, e),
        };
        ev.forceDeepInner(r, seen, demand) catch |e| return ev.walkTrace(T, x, e);
    };
}

/// The cells of `items` as a range task does them, while the walk would
/// otherwise wait on a busy cell before them. Whatever this forces is
/// speculated, and an effect gives up the rest: the walk that takes the
/// cells next reads them in order.
fn ahead(ev: *Evaluator, comptime T: type, items: []T) void {
    const saved = ev.par;
    ev.par.is_main = false;
    ev.par.cancelled = false;
    // The effects of what this forces park on its thunks, outside the
    // thunk this fiber is forcing, if any.
    const f = ev.fiber.?;
    const frames = f.effects.frames;
    f.effects.frames = 0;
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(ev.gpa);
    for (items) |*x| if (!ev.rangeStep(itemCell(T, x), true, &seen)) break;
    ev.clearFailure();
    ev.par = saved;
    f.effects.frames = frames;
}

/// `forceAttrs` without flattening a `//` union, for the lookups.
pub fn forceSet(ev: *Evaluator, v: Value, pos: Pos, ctx: []const u8) Error!Value {
    const r = try ev.force(v);
    if (r.kind() == .attrs) return r;
    return ev.typeError("a set", r, pos, ctx);
}

/// The attribute `s` of a forced value, null when it has none or is no set.
pub inline fn getAttr(v: Value, s: Sym) ?*value.Attr {
    if (v.asUnion()) |u| return u.get(s);
    if (v.kind() != .attrs) return null;
    return v.as(value.Attrs).get(s);
}

pub fn forceAttrs(ev: *Evaluator, v: Value, pos: Pos, ctx: []const u8) Error!*value.Attrs {
    const r = try ev.force(v);
    if (r.kind() == .attrs) return r.as(value.Attrs);
    return ev.typeError("a set", r, pos, ctx);
}

pub fn forceList(ev: *Evaluator, v: Value, pos: Pos, ctx: []const u8) Error!*value.List {
    const r = try ev.force(v);
    if (r.kind() == .list) return r.as(value.List);
    return ev.typeError("a list", r, pos, ctx);
}

pub fn forceInt(ev: *Evaluator, v: Value, pos: Pos, ctx: []const u8) Error!i64 {
    const r = try ev.force(v);
    return switch (r.view()) {
        .int => |i| i,
        else => ev.typeError("an integer", r, pos, ctx),
    };
}

/// A float; an integer converts.
pub fn forceFloat(ev: *Evaluator, v: Value, pos: Pos, ctx: []const u8) Error!f64 {
    const r = try ev.force(v);
    return switch (r.view()) {
        .int => |i| @floatFromInt(i),
        .float => |f| f,
        else => ev.typeError("a float", r, pos, ctx),
    };
}

pub fn forceBool(ev: *Evaluator, v: Value, pos: Pos, ctx: []const u8) Error!bool {
    const r = try ev.force(v);
    return switch (r) {
        .true => true,
        .false => false,
        else => ev.typeError("a Boolean", r, pos, ctx),
    };
}

pub fn forceString(ev: *Evaluator, v: Value, pos: Pos, ctx: []const u8) Error!*value.String {
    const r = try ev.force(v);
    if (r.kind() == .string) return r.as(value.String);
    return ev.typeError("a string", r, pos, ctx);
}

pub fn forceStringNoCtx(ev: *Evaluator, v: Value, pos: Pos, ctx: []const u8) Error![]const u8 {
    const s = try ev.forceString(v, pos, ctx);
    for (s.context()) |c| {
        if (!c.isStore()) continue;
        const e = ev.fail(.eval, pos, "the string '{s}' is not allowed to refer to a store path (such as '{s}')", .{ s.bytes(), c.path });
        if (ctx.len == 0) return e;
        return ev.addTrace(e, pos, "{s}", .{ctx});
    }
    return s.bytes();
}

pub fn forceFunction(ev: *Evaluator, v: Value, pos: Pos, ctx: []const u8) Error!Value {
    const r = try ev.force(v);
    switch (r.view()) {
        .lambda, .primop, .primop_app => return r,
        .attrs => |a| if (a.get(ev.s.__functor) != null) return r,
        else => {},
    }
    return ev.typeError("a function", r, pos, ctx);
}

/// The symbol of a string value, cached on the string.
pub fn forceSym(ev: *Evaluator, v: Value, pos: Pos, ctx: []const u8) Error!Sym {
    const s = try ev.forceString(v, pos, ctx);
    if (s.cachedSym()) |y| return y;
    const y = try ev.interner.intern(s.bytes());
    s.cacheSym(y);
    return y;
}

pub fn isDerivation(ev: *Evaluator, v: Value) Error!bool {
    const r = try ev.force(v);
    const t = getAttr(r, ev.s.type) orelse return false;
    const tv = try ev.forceCell(&t.cell);
    if (tv.kind() != .string) return false;
    return std.mem.eql(u8, tv.as(value.String).bytes(), "derivation");
}

// Thunk creation.

/// `code` for lazy evaluation in `env`, sharing the existing value or thunk
/// for a cheap expression.
pub inline fn maybeThunk(ev: *Evaluator, env: *Env, code: ir.Ref) Error!Value {
    const v = ev.maybeThunkRaw(env, code);
    if (v == .failed) return ev.pending;
    return v;
}

/// `maybeThunk` returning a plain word, `.failed` on error (see `evalRaw`).
fn maybeThunkRaw(ev: *Evaluator, env: *Env, code: ir.Ref) Value {
    switch (code.*) {
        .constant => |v| return v,
        .local => |l| {
            const v = lookup(env, l.depth, l.idx).get();
            // A slot of the env under construction (`let x = x;`): a thunk,
            // so forcing it reports infinite recursion instead of reading `empty`.
            if (v == .empty) return ev.lift(ev.mkThunk(env, code));
            return v;
        },
        .lambda => |l| return ev.lift(ev.mkLambda(env, l)),
        // `n - 1` and `a + b` on forced ints cannot fail except on overflow,
        // so compute them now instead of allocating a thunk.
        .binop => |b| if (b.op == .sub) if (forcedInt(env, b.a)) |x| if (forcedInt(env, b.b)) |y| {
            if (std.math.sub(i64, x, y) catch null) |r| if (Value.fitsImm(r)) return .immInt(r);
        },
        .concat => |c| if (!c.force_string and c.parts.len == 2) if (forcedInt(env, c.parts[0])) |x| if (forcedInt(env, c.parts[1])) |y| {
            if (std.math.add(i64, x, y) catch null) |r| if (Value.fitsImm(r)) return .immInt(r);
        },
        // `x.y` on a set that is already forced: the attribute's cell holds
        // what a fresh thunk would only look up, so share it.
        .select => |sel| {
            const v = ev.sharedSelect(env, sel.subject, sel.path, sel.default);
            if (v != .empty) return v;
        },
        .select1 => |sel| {
            const v = ev.sharedSelect(env, sel.subject, &.{.{ .static = sel.sym }}, sel.default);
            if (v != .empty) return v;
        },
        else => {},
    }
    return ev.lift(ev.mkThunk(env, code));
}

/// What a constant or a local holds, without evaluating anything.
inline fn peek(env: *Env, code: ir.Ref) ?Value {
    return switch (code.*) {
        .constant => |v| v,
        .local => |l| lookup(env, l.depth, l.idx).get(),
        else => null,
    };
}

inline fn forcedInt(env: *Env, code: ir.Ref) ?i64 {
    const v = peek(env, code) orelse return null;
    return if (v.tag() == .int) v.view().int else null;
}

/// The value `maybeThunk` can share for a select, `.empty` when there is
/// none, or `.failed`.
fn sharedSelect(ev: *Evaluator, env: *Env, subject: ir.Ref, path: []const ir.AttrElem, default: ?ir.Ref) Value {
    var v = peek(env, subject) orelse return .empty;
    for (path) |elem| {
        const s = switch (elem) {
            .static => |s| s,
            .dynamic => return .empty,
        };
        if (v.kind() != .attrs) return .empty;
        if (getAttr(v, s)) |a| {
            v = a.cell.get();
            if (v == .empty) return .empty;
        } else {
            v = ev.maybeThunkRaw(env, default orelse return .empty);
            if (v == .failed) return v;
            break;
        }
    }
    // Only what `==` cannot tell apart from a fresh thunk is shared.
    if (v.isThunk() or v.typeOf() == .lambda) return .empty;
    return v;
}

inline fn lookup(env: *Env, depth: u32, idx: u32) *Cell {
    var e = env;
    for (0..depth) |_| e = e.parent().?;
    e.markRead();
    return e.slot(idx);
}

// Application.

pub fn call1(ev: *Evaluator, f: Value, a: Value, pos: Pos) Error!Value {
    return ev.apply(f, &.{a}, pos);
}

pub fn call2(ev: *Evaluator, f: Value, a: Value, b: Value, pos: Pos) Error!Value {
    return ev.apply(f, &.{ a, b }, pos);
}

pub fn apply(ev: *Evaluator, func: Value, args: []const Value, pos: Pos) Error!Value {
    const r = ev.applyRaw(func, args, pos);
    if (r == .failed) return ev.pending;
    return r;
}

noinline fn applyRaw(ev: *Evaluator, func: Value, args_in: []const Value, pos: Pos) Value {
    // `call_limit` is the depth limit, or 0 in a profiled run, so one
    // compare serves both and the shadow stack costs a run without a
    // profile nothing; a branch of its own measured 1.5% of the instructions.
    if (ev.call_depth >= ev.call_limit) return ev.applySlow(func, args_in, pos);
    return @call(tail, applyBody, .{ ev, func, args_in, pos });
}

/// The call. The helpers only it calls are inlined into it; the profiled
/// copy calls them out of line, so this one keeps them.
noinline fn applyBody(ev: *Evaluator, func: Value, args_in: []const Value, pos: Pos) Value {
    return @call(.always_inline, applyImpl, .{ ev, func, args_in, pos, false });
}

/// A call of a profiled run, with the frames Rust iets's profile has: one per
/// lambda while it binds its argument, the last one while its body runs,
/// and one per further function an over-applied call reaches.
noinline fn applyProfiled(ev: *Evaluator, p: *profile.Stack, func: Value, args_in: []const Value, pos: Pos) Value {
    const d = p.depth();
    const r = @call(.always_inline, applyImpl, .{ ev, func, args_in, pos, true });
    p.unwind(d);
    return r;
}

inline fn applyImpl(ev: *Evaluator, func: Value, args_in: []const Value, pos: Pos, comptime profiled: bool) Value {
    const helper: std.builtin.CallModifier = if (profiled) .never_inline else .always_inline;
    ev.enterCall(pos) catch |e| return ev.stash(e);
    defer ev.call_depth -= 1;
    var cur = func;
    if (cur.isThunk()) {
        cur = ev.forceThunkRaw(cur);
        if (cur == .failed) return cur;
    }
    var args = args_in;
    // eval.cc:callFunction recurses through a functor, so its call depth
    // bounds the chain; this loop counts the chain against the same limit.
    var functors: u32 = 0;
    while (args.len > 0) {
        switch (cur.view()) {
            .lambda => |l| {
                var lam = l.lam;
                var fenv = l.env;
                var env2: *Env = undefined;
                var d: usize = 0;
                while (true) {
                    // `lam` and the lambdas in its body that extend its frame
                    // (`a: b: e`) take their arguments in one env.
                    var last = lam;
                    var n: usize = 1;
                    while (n < args.len and last.body.* == .lambda and last.body.lambda.base > 0) : (n += 1) last = last.body.lambda;
                    env2 = if (lam.no_env) fenv else @call(helper, frameEnv, .{ ev, fenv, lam, last.frame }) catch |e| return ev.stash(e);
                    var cur_lam = lam;
                    for (args[0..n], 0..) |a, i| {
                        if (i > 0) {
                            cur_lam = cur_lam.body.lambda;
                            if (profiled) ev.prof.?.unwind(d);
                        }
                        ev.stats.calls += 1;
                        if (profiled) d = ev.profEnterSlow(ev.prof.?, profile.frame(pos, cur_lam.name));
                        if (!cur_lam.no_env) @call(helper, bindParams, .{ ev, env2, cur_lam, a, pos }) catch |e| return ev.stash(e);
                    }
                    args = args[n..];
                    lam = last;
                    // `a: b: e` applied to two arguments with `b` in an env
                    // of its own: bind `b` without making its closure.
                    if (args.len > 0 and last.body.* == .lambda) {
                        if (profiled) ev.prof.?.unwind(d);
                        fenv = env2;
                        lam = last.body.lambda;
                        continue;
                    }
                    break;
                }
                cur = ev.evalRaw(env2, lam.body);
                if (cur == .failed) {
                    const e2 = ev.addTrace(ev.pending, lam.pos, "while calling {f}", .{LambdaDesc{ .ev = ev, .lam = lam }});
                    if (pos == .none) return ev.stash(e2);
                    return ev.stash(ev.addTrace(e2, pos, "from call site", .{}));
                }
                if (profiled) ev.prof.?.unwind(d);
            },
            .primop => |op| {
                if (args.len < op.arity) return ev.lift(ev.mkPrimOpApp(op, &.{}, args));
                const d = if (profiled) ev.profEnterSlow(ev.prof.?, profile.primopFrame(pos, op.sym)) else 0;
                cur = @call(helper, callPrimOp, .{ ev, op, args[0..op.arity], pos }) catch |e| return ev.stash(e);
                if (profiled) ev.prof.?.unwind(d);
                args = args[op.arity..];
            },
            .primop_app => |app| {
                const op = app.op;
                const have = app.args();
                const need = op.arity - have.len;
                if (args.len < need) return ev.lift(ev.mkPrimOpApp(op, have, args));
                var all: [8]Value = undefined;
                @memcpy(all[0..have.len], have);
                @memcpy(all[have.len..op.arity], args[0..need]);
                const d = if (profiled) ev.profEnterSlow(ev.prof.?, profile.primopFrame(pos, op.sym)) else 0;
                cur = @call(helper, callPrimOp, .{ ev, op, all[0..op.arity], pos }) catch |e| return ev.stash(e);
                if (profiled) ev.prof.?.unwind(d);
                args = args[need..];
            },
            .attrs => |a| {
                const functor = a.get(ev.s.__functor) orelse {
                    return ev.stash(ev.fail(.type, pos, "attempt to call something which is not a function but a set: {f}", .{print.short(ev, cur)}));
                };
                functors += 1;
                if (functors > max_call_depth) return ev.stash(ev.fail(.stack_overflow, pos, "stack overflow; max-call-depth exceeded", .{}));
                const f = ev.forceCell(&functor.cell) catch |e| return ev.stash(e);
                // The functor gets the set first, then the argument.
                cur = ev.applyRaw(f, &.{cur}, pos);
                if (cur == .failed) return cur;
            },
            else => {
                return ev.stash(ev.fail(.type, pos, "attempt to call something which is not a function but {s}: {f}", .{ cur.typeOf().show(), print.short(ev, cur) }));
            },
        }
    }
    return cur;
}

fn callPrimOp(ev: *Evaluator, op: *value.PrimOp, args: []const Value, pos: Pos) Error!Value {
    const f: *const RawPrimFn = @ptrCast(@alignCast(op.f));
    const r = f(ev, args, pos);
    if (r == .failed) return ev.addTrace(ev.pending, pos, "while calling the '{s}' builtin", .{op.name()});
    return r;
}

/// Profiles this evaluator's calls on `st`.
pub fn setProfile(ev: *Evaluator, st: *profile.Stack) void {
    ev.prof = st;
    ev.call_limit = 0;
}

/// A call past the depth limit, or any call of a profiled run.
noinline fn applySlow(ev: *Evaluator, func: Value, args: []const Value, pos: Pos) Value {
    const p = ev.prof orelse return applyBody(ev, func, args, pos);
    return applyProfiled(ev, p, func, args, pos);
}

/// Enters frame `f` on the shadow stack, when the run profiles, and
/// answers the depth to return to.
fn profEnter(ev: *Evaluator, f: u64) usize {
    const p = ev.prof orelse return 0;
    return ev.profEnterSlow(p, f);
}

noinline fn profEnterSlow(ev: *Evaluator, p: *profile.Stack, f: u64) usize {
    const d = p.depth();
    p.enter(ev.gpa, f);
    const prof = p.profile.?;
    // the arena is read only here, so a call that is not sampled does not touch it
    if (p.due(prof)) {
        const used = ev.local.arena.used;
        p.take(prof, used -| p.last_bytes);
        p.last_bytes = used;
    }
    return d;
}

inline fn profUnwind(ev: *Evaluator, d: usize) void {
    if (ev.prof) |p| p.unwind(d);
}

pub const PrimFn = fn (ev: *Evaluator, args: []const Value, pos: Pos) Error!Value;

/// What a primop object calls: `f` returning a plain word, `.failed` on
/// error, so the result comes back in a register (see `evalRaw`).
const RawPrimFn = fn (ev: *Evaluator, args: []const Value, pos: Pos) Value;

fn RawPrim(comptime f: *const PrimFn) type {
    return struct {
        fn run(ev: *Evaluator, args: []const Value, pos: Pos) Value {
            return @call(.always_inline, f, .{ ev, args, pos }) catch |e| ev.stash(e);
        }
    };
}

pub fn mkPrimOp(ev: *Evaluator, name: []const u8, arity: u8, comptime f: *const PrimFn) Error!Value {
    const o = try ev.local.arena.create(value.PrimOp);
    const raw: *const RawPrimFn = &RawPrim(f).run;
    o.* = .{ .arity = arity, .sym = try ev.sym(name), .name_ptr = name.ptr, .name_len = name.len, .f = @ptrCast(raw) };
    return .fromPtr(.ptr, o);
}

pub fn mkPrimOpApp(ev: *Evaluator, op: *value.PrimOp, a: []const Value, b: []const Value) Error!Value {
    const app = try ev.local.arena.createWithTail(value.PrimOpApp, Value, a.len + b.len);
    app.* = .{ .nargs = @intCast(a.len + b.len), .op = op };
    @memcpy(app.args()[0..a.len], a);
    @memcpy(app.args()[a.len..], b);
    return .fromPtr(.ptr, app);
}

const LambdaDesc = struct {
    ev: *Evaluator,
    lam: *const ir.Lambda,

    pub fn format(d: LambdaDesc, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (d.lam.name) |n| return w.print("'{s}'", .{d.ev.interner.nameStr(n)});
        try w.writeAll("anonymous lambda");
    }
};

fn lambdaName(ev: *Evaluator, lam: *const ir.Lambda) []const u8 {
    return if (lam.name) |n| ev.interner.name(n) else "anonymous lambda";
}

/// An env of `size` slots for a call of `lam` in the closure env `fenv`. A
/// lambda that extends its parent's frame starts from a copy of the
/// parent's slots, above the parent's env: a closure of `b: e` may be
/// called many times.
fn frameEnv(ev: *Evaluator, fenv: *Env, lam: *const ir.Lambda, size: u32) Error!*Env {
    if (lam.base == 0) return ev.allocEnv(fenv, size);
    const env2 = try ev.allocEnv(fenv.parent(), size);
    @memcpy(env2.slots()[0..lam.base], fenv.slots()[0..lam.base]);
    return env2;
}

/// `lam`'s params from `arg`, in `env2` from slot `lam.base` on.
fn bindParams(ev: *Evaluator, env2: *Env, lam: *const ir.Lambda, arg: Value, pos: Pos) Error!void {
    const slots = env2.slots() + lam.base;
    switch (lam.param) {
        .ident => slots[0] = .init(arg),
        .formals => |p| {
            const attrs = ev.forceSet(arg, lam.pos, "while evaluating the value passed for the lambda argument") catch |e| {
                if (pos == .none) return e;
                return ev.addTrace(e, pos, "from call site", .{});
            };
            var i: usize = 0;
            if (p.has_bind) {
                slots[0] = .init(arg);
                i = 1;
            }
            var used: usize = 0;
            // The formals and a flat set are both sorted by symbol: each
            // search starts where the last one ended.
            const flat_items: ?[]value.Attr = if (attrs.asUnion() == null) attrs.as(value.Attrs).attrs() else null;
            var lo: usize = 0;
            for (p.formals) |f| {
                const found: ?*value.Attr = if (flat_items) |items| blk: {
                    const j = lowerBoundSym(items, lo, f.sym);
                    lo = j;
                    if (j < items.len and items[j].sym == f.sym) {
                        lo = j + 1;
                        break :blk &items[j];
                    }
                    break :blk null;
                } else getAttr(attrs, f.sym);
                if (found) |a| {
                    used += 1;
                    slots[i] = .init(a.cell.get());
                } else if (f.default) |d| {
                    slots[i] = .init(try ev.maybeThunk(env2, d));
                } else {
                    const e = ev.fail(.type, lam.pos, "function '{s}' called without required argument '{s}'", .{ ev.lambdaName(lam), ev.interner.name(f.sym) });
                    return ev.addTrace(e, pos, "from call site", .{});
                }
                i += 1;
            }
            // Only a function without `...` needs the count, and so the flat set.
            if (!p.ellipsis) {
                const flat = attrs.as(value.Attrs);
                if (used != flat.len) for (flat.attrs()) |a| {
                    if (hasFormal(p.formals, a.sym)) continue;
                    const e = ev.fail(.type, lam.pos, "function '{s}' called with unexpected argument '{s}'", .{ ev.lambdaName(lam), ev.interner.name(a.sym) });
                    return ev.addTrace(e, pos, "from call site", .{});
                };
            }
        },
    }
}

/// The first index at or after `lo` whose symbol is not below `s`.
inline fn lowerBoundSym(items: []const value.Attr, lo_in: usize, s: Sym) usize {
    var lo = lo_in;
    var hi = items.len;
    const key = @backingInt(s);
    while (hi - lo > 8) {
        const mid = lo + (hi - lo) / 2;
        if (@backingInt(items[mid].sym) < key) lo = mid + 1 else hi = mid;
    }
    while (lo < hi and @backingInt(items[lo].sym) < key) lo += 1;
    return lo;
}

fn hasFormal(formals: []const ir.Formal, s: Sym) bool {
    for (formals) |f| if (f.sym == s) return true;
    return false;
}

/// Call `fun` with the auto-args `args` when it takes formals, as
/// `nix-instantiate --arg` does to the top-level value.
pub fn autoCall(ev: *Evaluator, fun: Value, args: *value.Attrs) Error!Value {
    const f = try ev.force(fun);
    if (f.tag() != .lambda) return f;
    const lam = f.untagged(value.Lambda).lam;
    switch (lam.param) {
        .ident => return f,
        .formals => |p| {
            var picked: std.ArrayList(value.Attr) = .empty;
            defer picked.deinit(ev.gpa);
            for (args.attrs()) |a| {
                if (p.ellipsis or hasFormal(p.formals, a.sym)) try picked.append(ev.gpa, a);
            }
            // eval.cc:autoCallFunction: a formal with no default that no
            // argument names stops it before the call
            if (!p.ellipsis) for (p.formals) |fm| {
                if (fm.default != null) continue;
                for (picked.items) |a| {
                    if (a.sym == fm.sym) break;
                } else return ev.fail(.eval, lam.pos, "cannot evaluate a function that has an argument without a value ('{s}')", .{ev.interner.name(fm.sym)});
            };
            const arg = try ev.mkAttrsSorted(picked.items);
            return ev.call1(f, arg, .none);
        },
    }
}

// Evaluation.

pub inline fn eval(ev: *Evaluator, env: *Env, code: ir.Ref) Error!Value {
    const v = ev.evalFast(env, code);
    if (v == .failed) return ev.pending;
    return v;
}

/// `evalRaw` with a constant or a forced variable read in place: the
/// commonest operands, which a call would pay `evalRaw`'s whole frame for.
inline fn evalFast(ev: *Evaluator, env: *Env, code: ir.Ref) Value {
    switch (code.*) {
        .constant => |v| return v,
        .local => |l| {
            const v = lookup(env, l.depth, l.idx).get();
            if (!v.isThunk()) return v;
        },
        else => {},
    }
    return ev.evalRaw(env, code);
}

/// The error `.failed` stands for.
fn stash(ev: *Evaluator, e: Error) Value {
    @branchHint(.cold);
    ev.pending = e;
    return .failed;
}

inline fn lift(ev: *Evaluator, r: Error!Value) Value {
    return r catch |e| ev.stash(e);
}

/// `eval` returning a plain word, `.failed` on error: an error union is
/// returned through memory, and its copy at every level of a deep
/// recursion stalls the store buffer.
///
/// Threaded: the dispatch has no frame of its own and tail-calls the
/// handler of the node's tag, so a constant costs no frame and each handler
/// saves only the registers it uses. A tail position (`let`, `with`, `if`,
/// `assert`, a missing attribute's default) tail-calls back here, so deep
/// chains of them take no stack.
noinline fn evalRaw(ev: *Evaluator, env: *Env, code: ir.Ref) Value {
    switch (code.*) {
        inline else => |_, tag| return @call(tail, @field(Node, @tagName(tag)), .{ ev, env, code }),
    }
}

/// Debug builds use the self-hosted backend, which has no tail calls.
const tail: std.builtin.CallModifier = if (builtin.zig_backend == .stage2_llvm) .always_tail else .auto;

/// The handlers of `evalRaw`, one per IR tag.
const Node = struct {
    noinline fn constant(_: *Evaluator, _: *Env, code: ir.Ref) Value {
        return code.constant;
    }

    noinline fn local(ev: *Evaluator, env: *Env, code: ir.Ref) Value {
        const l = code.local;
        const c = lookup(env, l.depth, l.idx);
        const v = c.get();
        if (!v.isThunk()) return v;
        const r = ev.forceThunkRaw(v);
        if (r != .failed and ev.par.is_main) c.set(r);
        return r;
    }

    noinline fn with_var(ev: *Evaluator, env: *Env, code: ir.Ref) Value {
        const w = code.with_var;
        return ev.lift(ev.evalWithVar(env, w.sym, w.withs, w.pos));
    }

    noinline fn cur_pos(ev: *Evaluator, _: *Env, code: ir.Ref) Value {
        return ev.lift(ev.mkPosAttrs(code.cur_pos));
    }

    noinline fn concat(ev: *Evaluator, env: *Env, code: ir.Ref) Value {
        const c = code.concat;
        return ev.lift(ev.evalConcat(env, c.force_string, c.parts, c.pos));
    }

    noinline fn search_path(ev: *Evaluator, env: *Env, code: ir.Ref) Value {
        const sp = code.search_path;
        return ev.lift(ev.evalSearchPath(env, sp.name, sp.pos));
    }

    noinline fn select(ev: *Evaluator, env: *Env, code: ir.Ref) Value {
        return ev.evalSelect(env, code.select);
    }

    noinline fn select_count(ev: *Evaluator, env: *Env, code: ir.Ref) Value {
        return ev.evalSelectCount(env, code.select_count);
    }

    noinline fn select1(ev: *Evaluator, env: *Env, code: ir.Ref) Value {
        const sel = &code.select1;
        const v = ev.evalFast(env, sel.subject);
        if (v == .failed) return v;
        const at = getAttr(v, sel.sym) orelse {
            if (sel.default) |d| {
                if (ev.lintOn(.or_non_attrs)) return ev.orDefault(env, v, d, sel.pos);
                return @call(tail, evalRaw, .{ ev, env, d });
            }
            return ev.selectMissing(v, sel.sym, sel.pos);
        };
        const x = at.cell.get();
        if (!x.isThunk()) return x;
        const r = ev.forceThunkRaw(x);
        if (r == .failed) return ev.attrFailed(at.pos, sel.sym);
        if (ev.par.is_main) at.cell.set(r);
        return r;
    }

    noinline fn has_attr(ev: *Evaluator, env: *Env, code: ir.Ref) Value {
        return ev.evalHasAttr(env, code.has_attr.subject, code.has_attr.path);
    }

    noinline fn attrs(ev: *Evaluator, env: *Env, code: ir.Ref) Value {
        return ev.lift(ev.evalAttrs(env, code.attrs));
    }

    noinline fn list(ev: *Evaluator, env: *Env, code: ir.Ref) Value {
        return ev.lift(ev.evalList(env, code.list));
    }

    noinline fn lambda(ev: *Evaluator, env: *Env, code: ir.Ref) Value {
        return ev.lift(ev.mkLambda(env, code.lambda));
    }

    noinline fn apply(ev: *Evaluator, env: *Env, code: ir.Ref) Value {
        const a = &code.apply;
        const f = ev.evalFast(env, a.func);
        if (f == .failed) return f;
        const args = a.args();
        var buf: [8]Value = undefined;
        if (args.len > buf.len) return ev.lift(ev.applyMany(env, f, args, a.pos));
        for (args, 0..) |arg, i| {
            buf[i] = ev.maybeThunkRaw(env, arg);
            if (buf[i] == .failed) return buf[i];
        }
        return ev.applyRaw(f, buf[0..args.len], a.pos);
    }

    noinline fn let(ev: *Evaluator, env: *Env, code: ir.Ref) Value {
        const l = code.let;
        if (l.base != ir.Let.own_env) {
            // The lambda's call made the slots; `inherit x` reads its
            // params, which live in the same env.
            ev.fillRecSlots(env, env, l.base, l.binds, l.from, false) catch |e| return ev.stash(e);
            return @call(tail, evalRaw, .{ ev, env, l.body });
        }
        const env2 = ev.allocRecEnv(env, l.binds, l.from, false) catch |e| return ev.stash(e);
        return @call(tail, evalRaw, .{ ev, env2, l.body });
    }

    noinline fn with(ev: *Evaluator, env: *Env, code: ir.Ref) Value {
        const w = &code.with;
        const env2 = ev.allocEnv(env, 1) catch |e| return ev.stash(e);
        const scope = ev.maybeThunkRaw(env, w.scope);
        if (scope == .failed) return scope;
        env2.slot(0).* = .init(scope);
        return @call(tail, evalRaw, .{ ev, env2, w.body });
    }

    noinline fn @"if"(ev: *Evaluator, env: *Env, code: ir.Ref) Value {
        const i = &code.@"if";
        const c = ev.evalFast(env, i.cond);
        const branch = switch (c) {
            .true => i.branches[0],
            .false => i.branches[1],
            else => return ev.boolFailed(c, i.pos, "while evaluating a branch condition"),
        };
        return @call(tail, evalRaw, .{ ev, env, branch });
    }

    noinline fn assert(ev: *Evaluator, env: *Env, code: ir.Ref) Value {
        const a = &code.assert;
        const c = ev.evalFast(env, a.cond);
        switch (c) {
            .true => {},
            .false => return ev.stash(ev.fail(.assert, a.pos, "assertion failed", .{})),
            else => return ev.boolFailed(c, a.pos, "in the condition of the assert statement"),
        }
        return @call(tail, evalRaw, .{ ev, env, a.body });
    }

    noinline fn not(ev: *Evaluator, env: *Env, code: ir.Ref) Value {
        const n = &code.not;
        const c = ev.evalFast(env, n.e);
        return switch (c) {
            .true => .false,
            .false => .true,
            else => ev.boolFailed(c, n.pos, "in the argument of the not operator"),
        };
    }

    noinline fn neg(ev: *Evaluator, env: *Env, code: ir.Ref) Value {
        const n = &code.neg;
        const v = ev.evalFast(env, n.e);
        if (v == .failed) return v;
        return ev.lift(ev.arith(.immInt(0), v, .sub, n.pos));
    }

    noinline fn binop(ev: *Evaluator, env: *Env, code: ir.Ref) Value {
        const b = &code.binop;
        return ev.lift(ev.evalBinop(env, b.op, b.a, b.b, b.pos));
    }

    /// The import thunk applies an `importRaw` primop, as in Rust iets, so
    /// an error inside the file carries that frame, with no position.
    noinline fn import_file(ev: *Evaluator, _: *Env, code: ir.Ref) Value {
        // a profile names the frame the way Rust iets's primop does
        const d = if (ev.prof != null) ev.profEnter(profile.primopFrame(.none, ev.interner.intern("importRaw") catch return ev.stash(error.OutOfMemory))) else 0;
        const v = import_.load(ev, code.import_file) catch |e|
            return ev.stash(ev.addTrace(e, .none, "while calling the 'importRaw' builtin", .{}));
        ev.profUnwind(d);
        return v;
    }
};

/// A condition that is `.failed` or not a Boolean.
noinline fn boolFailed(ev: *Evaluator, c: Value, pos: Pos, ctx: []const u8) Value {
    @branchHint(.cold);
    if (c == .failed) return c;
    return ev.stash(ev.typeError("a Boolean", c, pos, ctx));
}

noinline fn selectMissing(ev: *Evaluator, v: Value, name: Sym, pos: Pos) Value {
    @branchHint(.cold);
    _ = ev.forceSet(v, pos, "while selecting an attribute") catch |e| return ev.stash(e);
    return ev.stash(ev.missingAttr(name, pos));
}

noinline fn attrFailed(ev: *Evaluator, pos: Pos, name: Sym) Value {
    @branchHint(.cold);
    return ev.stash(ev.addTrace(ev.pending, pos, "while evaluating the attribute '{s}'", .{ev.interner.name(name)}));
}

noinline fn evalHasAttr(ev: *Evaluator, env: *Env, subject: ir.Ref, path: []const ir.AttrElem) Value {
    var v = ev.evalFast(env, subject);
    if (v == .failed) return v;
    for (path) |elem| {
        const name = switch (elem) {
            .static => |n| n,
            .dynamic => ev.attrName(env, elem) catch |e| return ev.stash(e),
        };
        if (v.isThunk()) {
            v = ev.forceThunkRaw(v);
            if (v == .failed) return v;
        }
        const at = getAttr(v, name) orelse return .false;
        v = at.cell.get();
    }
    return .true;
}

noinline fn evalSearchPath(ev: *Evaluator, env: *Env, name_ir: ir.Ref, pos: Pos) Error!Value {
    const n = try ev.eval(env, name_ir);
    const name = try ev.forceStringNoCtx(n, pos, "while evaluating a path segment");
    return ev.mkPath(try import_.findFile(ev, ev.config.search_path, name, pos));
}

fn evalList(ev: *Evaluator, env: *Env, items: []const ir.Ref) Error!Value {
    const l = try ev.allocList(items.len);
    for (l.raw(), items) |*c, item| c.* = .init(try ev.maybeThunk(env, item));
    return .fromPtr(.ptr, l);
}

noinline fn applyMany(ev: *Evaluator, env: *Env, f: Value, args_ir: []const ir.Ref, pos: Pos) Error!Value {
    const args = try ev.local.arena.allocSlice(Value, args_ir.len);
    for (args_ir, args) |arg, *out| out.* = try ev.maybeThunk(env, arg);
    return ev.apply(f, args, pos);
}

fn evalBinop(ev: *Evaluator, env: *Env, op: ir.BinOp, l: ir.Ref, r: ir.Ref, pos: Pos) Error!Value {
    switch (op) {
        .@"and" => {
            if (!try ev.evalBool(env, l, pos, "in the left operand of the AND (&&) operator")) return .false;
            return .fromBool(try ev.evalBool(env, r, pos, "in the right operand of the AND (&&) operator"));
        },
        .@"or" => {
            if (try ev.evalBool(env, l, pos, "in the left operand of the OR (||) operator")) return .true;
            return .fromBool(try ev.evalBool(env, r, pos, "in the right operand of the OR (||) operator"));
        },
        .impl => {
            if (!try ev.evalBool(env, l, pos, "in the left operand of the IMPL (->) operator")) return .true;
            return .fromBool(try ev.evalBool(env, r, pos, "in the right operand of the IMPL (->) operator"));
        },
        .update => {
            // The right operand first, as eval.cc:ExprOpUpdate::evalForUpdate:
            // `tryEval (1 // throw "x")` catches the throw.
            const b = try ev.forceSet(try ev.eval(env, r), pos, "in the right operand of the update (//) operator");
            const a = try ev.forceSet(try ev.eval(env, l), pos, "in the left operand of the update (//) operator");
            if (census.enabled) return ev.censusUpdate(a, b, r, pos);
            return ev.updateAttrs(a, b);
        },
        else => {},
    }
    const a = try ev.eval(env, l);
    const b = try ev.eval(env, r);
    return switch (op) {
        .eq => .fromBool(try ev.eqOperator(a, b, pos)),
        .ne => .fromBool(!try ev.eqOperator(a, b, pos)),
        .lt => .fromBool(try ev.lessThan(a, b, pos)),
        .ge => .fromBool(!try ev.lessThan(a, b, pos)),
        .concat_lists => {
            const x = try ev.forceList(a, pos, "in the left operand of the list concatenation operator");
            const y = try ev.forceList(b, pos, "in the right operand of the list concatenation operator");
            return ev.concatLists(&.{ x, y });
        },
        .sub => ev.arith(a, b, .sub, pos),
        .mul => ev.arith(a, b, .mul, pos),
        .div => ev.arith(a, b, .div, pos),
        .@"and", .@"or", .impl, .update => unreachable,
    };
}

fn evalBool(ev: *Evaluator, env: *Env, code: ir.Ref, pos: Pos, ctx: []const u8) Error!bool {
    const v = try ev.eval(env, code);
    return switch (v) {
        .true => true,
        .false => false,
        else => ev.typeError("a Boolean", v, pos, ctx),
    };
}

noinline fn evalWithVar(ev: *Evaluator, env: *Env, s: Sym, withs: []const u32, pos: Pos) Error!Value {
    var e = env;
    var walked: u32 = 0;
    for (withs) |d| {
        while (walked < d) : (walked += 1) e = e.parent().?;
        e.markRead();
        const attrs = try ev.forceSet(e.slot(0).get(), pos, "while evaluating the first subexpression of a with expression");
        e.slot(0).set(attrs);
        if (getAttr(attrs, s)) |a| return ev.forceCell(&a.cell);
    }
    if (ev.globals.get(s)) |v| return ev.force(v);
    return ev.fail(.undefined_var, pos, "undefined variable '{s}'", .{ev.interner.name(s)});
}

fn attrName(ev: *Evaluator, env: *Env, elem: ir.AttrElem) Error!Sym {
    return switch (elem) {
        .static => |s| s,
        .dynamic => |d| ev.forceSym(try ev.eval(env, d), d.pos(), "while evaluating an attribute name"),
    };
}

fn evalSelect(ev: *Evaluator, env: *Env, s: *const ir.Select) Value {
    var v = ev.evalFast(env, s.subject);
    if (v == .failed) return v;
    for (s.path) |elem| {
        const name = switch (elem) {
            .static => |n| n,
            .dynamic => ev.attrName(env, elem) catch |e| return ev.stash(e),
        };
        const at = blk: {
            if (s.default) |d| {
                if (getAttr(v, name)) |a| break :blk a;
                if (ev.lintOn(.or_non_attrs)) return ev.orDefault(env, v, d, s.pos);
                return ev.evalRaw(env, d);
            }
            if (v.isThunk()) {
                v = ev.forceThunkRaw(v);
                if (v == .failed) return v;
            }
            if (getAttr(v, name)) |a| break :blk a;
            _ = ev.forceSet(v, s.pos, "while selecting an attribute") catch |e| return ev.stash(e);
            return ev.stash(ev.missingAttr(name, s.pos));
        };
        v = at.cell.get();
        if (v.isThunk()) {
            const r = ev.forceThunkRaw(v);
            if (r == .failed)
                return ev.stash(ev.addTrace(ev.pending, at.pos, "while evaluating the attribute '{f}'", .{AttrPath{ .ev = ev, .env = env, .path = s.path }}));
            if (ev.par.is_main) at.cell.set(r);
            v = r;
        }
    }
    return v;
}

/// `evalSelect` for `select_count`: an element named `revCount` reads its
/// cell through `purity.countRead`, which reports `rev-count` here when the
/// cell holds a tree's lazy count.
noinline fn evalSelectCount(ev: *Evaluator, env: *Env, s: *const ir.Select) Value {
    @branchHint(.cold);
    var v = ev.evalFast(env, s.subject);
    if (v == .failed) return v;
    const rev_count = ev.s.revCount;
    for (s.path) |elem| {
        const name = ev.attrName(env, elem) catch |e| return ev.stash(e);
        const at = getAttr(v, name) orelse {
            const d = s.default orelse {
                _ = ev.forceSet(v, s.pos, "while selecting an attribute") catch |e| return ev.stash(e);
                return ev.stash(ev.missingAttr(name, s.pos));
            };
            if (v.typeOf() != .set and ev.lintOn(.or_non_attrs)) return ev.orDefault(env, v, d, s.pos);
            return ev.evalRaw(env, d);
        };
        const r = (if (name == rev_count) lint_mod.purity.countRead(ev, &at.cell, s.pos) else ev.forceCell(&at.cell)) catch |e|
            return ev.stash(ev.addTrace(e, at.pos, "while evaluating the attribute '{f}'", .{AttrPath{ .ev = ev, .env = env, .path = s.path }}));
        v = r;
    }
    return v;
}

/// `x.a or d` falls back to `d`, with the lint on: out of line, so the
/// select handlers keep their frameless tail call when it is off.
noinline fn orDefault(ev: *Evaluator, env: *Env, v: Value, d: ir.Ref, pos: Pos) Value {
    if (v.typeOf() != .set) lint_mod.coerce.orNonAttrs(ev, v, pos) catch |e| return ev.stash(e);
    return ev.evalRaw(env, d);
}

fn missingAttr(ev: *Evaluator, name: Sym, pos: Pos) Error {
    return ev.fail(.missing_attr, pos, "attribute '{s}' missing", .{ev.interner.name(name)});
}

const AttrPath = struct {
    ev: *Evaluator,
    env: *Env,
    path: []const ir.AttrElem,

    pub fn format(p: AttrPath, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (p.path, 0..) |e, i| {
            if (i > 0) try w.writeByte('.');
            switch (e) {
                .static => |s| try w.writeAll(p.ev.interner.name(s)),
                .dynamic => |d| {
                    const saved = p.ev.failure;
                    p.ev.failure = null;
                    defer {
                        p.ev.clearFailure();
                        p.ev.failure = saved;
                    }
                    const v = p.ev.eval(p.env, d) catch {
                        try w.writeAll("\"${...}\"");
                        continue;
                    };
                    if (v.kind() == .string) try w.writeAll(v.as(value.String).bytes()) else try w.writeAll("\"${...}\"");
                },
            }
        }
    }
};

/// The env of `let` and `rec { }`: the binds, then the `from` thunks.
fn allocRecEnv(ev: *Evaluator, env: *Env, binds: []const ir.Bind, from: []const ir.Ref, overrides: bool) Error!*Env {
    const env2 = try ev.allocEnv(env, binds.len + from.len);
    try ev.fillRecSlots(env, env2, 0, binds, from, overrides);
    return env2;
}

/// The slots of recursive bindings in `env2` from `base` on; `inherit x`
/// reads `env`.
fn fillRecSlots(ev: *Evaluator, env: *Env, env2: *Env, base: u32, binds: []const ir.Bind, from: []const ir.Ref, overrides: bool) Error!void {
    const slots = env2.slots() + base;
    for (binds, 0..) |b, i| {
        slots[i] = .init(switch (b.scope) {
            .outer => try ev.maybeThunk(env, b.value),
            // eval.cc:ExprAttrs::eval makes a real thunk of every binding when
            // `__overrides` is there, so the override reaches the others.
            else => if (overrides) try ev.mkThunk(env2, b.value) else try ev.maybeThunk(env2, b.value),
        });
    }
    for (from, 0..) |f, j| slots[binds.len + j] = .init(try ev.maybeThunk(env2, f));
}

/// The env holding the `inherit (e)` source thunks of a plain set.
fn inheritEnv(ev: *Evaluator, env: *Env, from: []const ir.Ref) Error!?*Env {
    if (from.len == 0) return null;
    const e = try ev.allocEnv(env, from.len);
    for (from, 0..) |f, j| e.slot(j).* = .init(try ev.maybeThunk(env, f));
    return e;
}

fn evalAttrs(ev: *Evaluator, env: *Env, a: *const ir.Attrs) Error!Value {
    if (a.dynamic.len == 0 and a.overrides == null) {
        const out = try ev.allocAttrs(a.binds.len);
        ev.censusOrigin(out, .lit);
        const items = out.raw();
        if (a.rec) {
            const env2 = try ev.allocRecEnv(env, a.binds, a.from, false);
            for (a.binds, 0..) |b, i| items[i] = .{ .sym = b.sym, .pos = b.pos, .cell = .init(env2.slot(i).get()) };
        } else {
            const ie = try ev.inheritEnv(env, a.from);
            for (a.binds, 0..) |b, i| {
                const v = if (b.scope == .from) try ev.maybeThunk(ie.?, b.value) else try ev.maybeThunk(env, b.value);
                items[i] = .{ .sym = b.sym, .pos = b.pos, .cell = .init(v) };
            }
        }
        return .fromPtr(.ptr, out);
    }
    var entries: std.ArrayList(value.Attr) = try .initCapacity(ev.gpa, a.binds.len + a.dynamic.len);
    defer entries.deinit(ev.gpa);
    var dyn_env = env;
    if (a.rec) {
        const env2 = try ev.allocRecEnv(env, a.binds, a.from, a.overrides != null);
        dyn_env = env2;
        for (a.binds, 0..) |b, i| entries.appendAssumeCapacity(.{ .sym = b.sym, .pos = b.pos, .cell = .init(env2.slot(i).get()) });
        if (a.overrides) |oi| {
            const ov = try ev.forceAttrs(env2.slot(oi).get(), a.pos, "while evaluating the `__overrides` attribute");
            for (ov.attrs()) |o| {
                if (findBind(a.binds, o.sym)) |j| {
                    entries.items[j].cell = .init(o.cell.get());
                    env2.slot(j).set(o.cell.get());
                } else try entries.append(ev.gpa, .{ .sym = o.sym, .pos = o.pos, .cell = .init(o.cell.get()) });
            }
        }
    } else {
        const ie = try ev.inheritEnv(env, a.from);
        for (a.binds) |b| {
            const v = if (b.scope == .from) try ev.maybeThunk(ie.?, b.value) else try ev.maybeThunk(env, b.value);
            entries.appendAssumeCapacity(.{ .sym = b.sym, .pos = b.pos, .cell = .init(v) });
        }
    }
    for (a.dynamic) |d| {
        const nv = try ev.eval(dyn_env, d.name);
        if (nv == .null) continue;
        const name = try ev.forceStringNoCtx(nv, d.pos, "while evaluating the name of a dynamic attribute");
        const s = try ev.interner.intern(name);
        for (entries.items) |e| {
            if (e.sym == s) return ev.fail(.eval, d.pos, "dynamic attribute '{s}' already defined at {f}", .{ name, ev.files.at(e.pos) });
        }
        try entries.append(ev.gpa, .{ .sym = s, .pos = d.pos, .cell = .init(try ev.maybeThunk(dyn_env, d.value)) });
    }
    return ev.mkAttrs(entries.items, a.pos);
}

fn findBind(binds: []const ir.Bind, s: Sym) ?usize {
    for (binds, 0..) |b, i| if (b.sym == s) return i;
    return null;
}

fn evalConcat(ev: *Evaluator, env: *Env, force_string: bool, parts: []const ir.Ref, pos: Pos) Error!Value {
    var first = !force_string;
    var first_type: value.Type = .string;
    var n: i64 = 0;
    var nf: f64 = 0;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ev.gpa);
    var ctx: std.ArrayList(Ctx) = .empty;
    defer ctx.deinit(ev.gpa);
    for (parts) |part| {
        const v = try ev.eval(env, part);
        const ppos = if (part.pos() == .none) pos else part.pos();
        if (first) first_type = v.typeOf();
        switch (first_type) {
            .int => switch (v.view()) {
                .int => |i| n = std.math.add(i64, n, i) catch
                    return ev.fail(.eval, ppos, "integer overflow in adding {d} + {d}", .{ n, i }),
                .float => |f| {
                    first_type = .float;
                    nf = @as(f64, @floatFromInt(n)) + f;
                },
                else => return ev.fail(.eval, ppos, "cannot add {s} to an integer", .{v.typeOf().show()}),
            },
            .float => switch (v.view()) {
                .int => |i| nf += @floatFromInt(i),
                .float => |f| nf += f,
                else => return ev.fail(.eval, ppos, "cannot add {s} to a float", .{v.typeOf().show()}),
            },
            else => try ev.coerceToString(v, &out, &ctx, ppos, "while evaluating a path segment", .{
                .copy_to_store = first_type == .string,
                .canonicalize = !first,
            }),
        }
        first = false;
    }
    switch (first_type) {
        .int => return ev.mkInt(n),
        .float => return ev.mkFloat(nf),
        .path => {
            for (ctx.items) |c| if (c.isStore())
                return ev.fail(.eval, pos, "a string that refers to a store path cannot be appended to a path", .{});
            return ev.mkPath(try canonPath(ev.local.arena.allocator(), out.items));
        },
        else => return ev.mkStringCtx(out.items, ctx.items),
    }
}

/// Mirrors file-system.cc:canonPath without symlink resolution: collapse
/// `//`, `.` and `..`, drop a trailing slash.
pub fn canonPath(gpa: std.mem.Allocator, p: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(gpa, p.len + 1);
    var it = std.mem.tokenizeScalar(u8, p, '/');
    while (it.next()) |c| {
        if (std.mem.eql(u8, c, ".")) continue;
        if (std.mem.eql(u8, c, "..")) {
            if (std.mem.lastIndexOfScalar(u8, out.items, '/')) |i| out.shrinkRetainingCapacity(i);
            continue;
        }
        out.appendAssumeCapacity('/');
        out.appendSliceAssumeCapacity(c);
    }
    if (out.items.len == 0) out.appendAssumeCapacity('/');
    return out.items;
}

/// `a // b`. A large left side is not copied: the result is a union that
/// probes `b`, then `a`. Small left sides, and unions past the leaf budget,
/// merge flat.
pub fn updateAttrs(ev: *Evaluator, av: Value, bv: Value) Error!Value {
    const U = value.Union;
    const a_small = av.asUnion() == null and av.as(value.Attrs).len < U.min_left;
    if (av.asUnion() == null and av.as(value.Attrs).len == 0) return bv;
    if (bv.asUnion() == null and bv.as(value.Attrs).len == 0) return av;
    if (!a_small) {
        var abuf: [2]*value.Attrs = undefined;
        var bbuf: *value.Attrs = undefined;
        var la = leaves(av, &abuf[0]);
        const lb = leaves(bv, &bbuf);
        if (la.len + lb.len > U.max_leaves) {
            la = abuf[0..1];
            // `base // o1 // o2 ...`: past the leaf budget, merge the small
            // leaves after a dominant first one and keep that one shared,
            // where flattening it all copied the base at every overflow.
            if (av.asUnion()) |ua| if (ua.flat_cache.load(.acquire) == null) {
                const ls = ua.leaves();
                var rest: usize = 0;
                for (ls[1..]) |l| rest += l.len;
                if (ls[0].len > rest and 2 + lb.len <= U.max_leaves) {
                    abuf = .{ ls[0], try U.flatten(ls[1..]) };
                    la = abuf[0..2];
                }
            };
            if (la.len == 1) abuf[0] = av.as(value.Attrs);
        }
        if (la.len + lb.len <= U.max_leaves) {
            const n = la.len + lb.len;
            const u = try ev.local.arena.createWithTail(U, *value.Attrs, n);
            const before = ev.local.arena.used - (@sizeOf(U) + n * 8);
            ev.count(.update, before);
            u.* = .{ .nleaves = @intCast(n) };
            @memcpy(u.leaves()[0..la.len], la);
            @memcpy(u.leaves()[la.len..], lb);
            if (census.enabled) {
                const c = &ev.local.arena.census;
                c.noteAttrs(@ptrCast(u), .upd, c.lenOf(av.obj()) + c.lenOf(bv.obj()));
            }
            return .fromPtr(.ptr, u);
        }
    }
    const a = av.as(value.Attrs);
    const b = bv.as(value.Attrs);
    const aa = a.attrs();
    const bb = b.attrs();
    var i: usize = 0;
    var j: usize = 0;
    var common: usize = 0;
    while (i < aa.len and j < bb.len) {
        const x = @backingInt(aa[i].sym);
        const y = @backingInt(bb[j].sym);
        if (x < y) i += 1 else if (x > y) j += 1 else {
            common += 1;
            i += 1;
            j += 1;
        }
    }
    const before = ev.local.arena.used;
    const out = try ev.allocAttrs(aa.len + bb.len - common);
    ev.stats.bytes.getPtr(.attrs).* -= ev.local.arena.used - before;
    ev.count(.update, before);
    ev.censusOrigin(out, .upd);
    const items = out.raw();
    i = 0;
    j = 0;
    var k: usize = 0;
    while (i < aa.len and j < bb.len) : (k += 1) {
        const x = @backingInt(aa[i].sym);
        const y = @backingInt(bb[j].sym);
        if (x < y) {
            items[k] = aa[i];
            i += 1;
        } else {
            items[k] = bb[j];
            j += 1;
            if (x == y) i += 1;
        }
    }
    for (aa[i..]) |x| {
        items[k] = x;
        k += 1;
    }
    for (bb[j..]) |x| {
        items[k] = x;
        k += 1;
    }
    return .fromPtr(.ptr, out);
}

/// `updateAttrs` with the census of it. The update flattens union
/// operands, which marks them iterated; their marks are put back so a use
/// counts once, as an operand.
fn censusUpdate(ev: *Evaluator, a: Value, b: Value, r: ir.Ref, pos: Pos) Error!Value {
    const path = census.updPath(a, b);
    const ma = value.setMarks(a.obj()).*;
    const mb = value.setMarks(b.obj()).*;
    const before = ev.local.arena.used;
    const out = try ev.updateAttrs(a, b);
    value.setMarks(a.obj()).* = ma;
    value.setMarks(b.obj()).* = mb;
    const c = &ev.local.arena.census;
    c.upd.nested_right += @intFromBool(r.* == .binop and r.binop.op == .update);
    const file: ?census.UpdSite = if (ev.files.fileOf(pos)) |f| .{ .id = f.file.id, .name = f.file.path } else null;
    c.noteUpd(path, a.obj(), b.obj(), out.obj(), ev.local.arena.used - before, file);
    return out;
}

/// The leaves of a set as a union holds them: its own, its flat copy, or
/// itself, stored in `one`.
fn leaves(v: Value, one: **value.Attrs) []*value.Attrs {
    if (v.asUnion()) |u| {
        if (u.flat_cache.load(.acquire)) |f| {
            one.* = f;
            return @as([*]*value.Attrs, @ptrCast(one))[0..1];
        }
        return u.leaves();
    }
    one.* = v.as(value.Attrs);
    return @as([*]*value.Attrs, @ptrCast(one))[0..1];
}

pub fn concatLists(ev: *Evaluator, lists: []const *value.List) Error!Value {
    var total: usize = 0;
    for (lists) |l| total += l.len;
    for (lists) |l| if (l.len == total) return .fromPtr(.ptr, l);
    const out = try ev.allocList(total);
    var k: usize = 0;
    for (lists) |l| for (l.cells()) |c| {
        out.raw()[k] = c;
        k += 1;
    };
    return .fromPtr(.ptr, out);
}

pub const ArithOp = enum {
    add,
    sub,
    mul,
    div,

    fn verb(op: ArithOp) []const u8 {
        return switch (op) {
            .add => "adding",
            .sub => "subtracting",
            .mul => "multiplying",
            .div => "dividing",
        };
    }

    fn symbol(op: ArithOp) []const u8 {
        return switch (op) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
        };
    }

    fn ctx(op: ArithOp, first: bool) []const u8 {
        return switch (op) {
            .add => if (first) "while evaluating the first argument of the addition" else "while evaluating the second argument of the addition",
            .sub => if (first) "while evaluating the first argument of the subtraction" else "while evaluating the second argument of the subtraction",
            .mul => if (first) "while evaluating the first argument of the multiplication" else "while evaluating the second argument of the multiplication",
            .div => if (first) "while evaluating the first operand of the division" else "while evaluating the second operand of the division",
        };
    }
};

pub fn arith(ev: *Evaluator, a_in: Value, b_in: Value, comptime op: ArithOp, pos: Pos) Error!Value {
    const a = try ev.force(a_in);
    const b = try ev.force(b_in);
    if (a.typeOf() == .float or b.typeOf() == .float) {
        const x = try ev.forceFloat(a, pos, op.ctx(true));
        const y = try ev.forceFloat(b, pos, op.ctx(false));
        if (op == .div and y == 0) return ev.fail(.eval, pos, "division by zero", .{});
        return ev.mkFloat(switch (op) {
            .add => x + y,
            .sub => x - y,
            .mul => x * y,
            .div => x / y,
        });
    }
    const x = try ev.forceInt(a, pos, op.ctx(true));
    const y = try ev.forceInt(b, pos, op.ctx(false));
    if (op == .div and y == 0) return ev.fail(.eval, pos, "division by zero", .{});
    const r = switch (op) {
        .add => std.math.add(i64, x, y),
        .sub => std.math.sub(i64, x, y),
        .mul => std.math.mul(i64, x, y),
        .div => if (x == std.math.minInt(i64) and y == -1) error.Overflow else @divTrunc(x, y),
    } catch return ev.fail(.eval, pos, "integer overflow in {s} {d} {s} {d}", .{ op.verb(), x, op.symbol(), y });
    return ev.mkInt(r);
}

// Coercion, equality, ordering: eval.cc:coerceToString, eqValues, CompareValues.

pub const CoerceOpts = struct {
    /// Also convert ints, floats, bools, null and lists, as `toString` does.
    coerce_more: bool = false,
    /// Turn paths into store paths.
    copy_to_store: bool = true,
    /// False only for the first part of an interpolated path, which keeps a trailing slash.
    canonicalize: bool = true,
};

/// Append the string form of `v` to `out`, its context to `ctx`.
pub fn coerceToString(ev: *Evaluator, v_in: Value, out: *std.ArrayList(u8), ctx: *std.ArrayList(Ctx), pos: Pos, err_ctx: []const u8, opts: CoerceOpts) Error!void {
    try ev.enterCall(pos);
    defer ev.call_depth -= 1;
    const v = try ev.force(v_in);
    switch (v.view()) {
        .string => |s| {
            try out.appendSlice(ev.gpa, s.bytes());
            try ctx.appendSlice(ev.gpa, s.context());
            return;
        },
        .path => |p| {
            if (opts.copy_to_store) {
                const sp = try ev.copyPathToStore(p.bytes(), pos);
                try lint_mod.coerce.pathCopy(ev, p.bytes(), sp, pos);
                try out.appendSlice(ev.gpa, sp);
                try ctx.append(ev.gpa, .{ .kind = .opaque_path, .path = sp });
            } else {
                try out.appendSlice(ev.gpa, p.bytes());
                if (!ev.isStorePathText(p.bytes())) try ctx.append(ev.gpa, .{ .kind = .impure_path, .path = p.bytes() });
            }
            return;
        },
        .attrs => |a| {
            if (a.get(ev.s.__toString)) |f| {
                const fv = try ev.forceCell(&f.cell);
                const r = try ev.call1(fv, v, pos);
                return ev.coerceToString(r, out, ctx, pos, "while evaluating the result of the `__toString` attribute", opts);
            }
            if (a.get(ev.s.outPath)) |o| return ev.coerceToString(o.cell.get(), out, ctx, pos, err_ctx, opts);
        },
        .bool => |b| if (opts.coerce_more) {
            if (b) try out.append(ev.gpa, '1');
            return;
        },
        .int => |i| if (opts.coerce_more) {
            var buf: [24]u8 = undefined;
            try out.appendSlice(ev.gpa, std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable);
            return;
        },
        .float => |f| if (opts.coerce_more) {
            // std::to_string(double) is %f, which keeps a NaN's sign.
            var buf: [400]u8 = undefined;
            const s = if (std.math.isNan(f))
                (if (std.math.signbit(f)) "-nan" else "nan")
            else if (std.math.isInf(f))
                (if (f < 0) "-inf" else "inf")
            else
                std.fmt.bufPrint(&buf, "{d:.6}", .{f}) catch unreachable;
            try out.appendSlice(ev.gpa, s);
            return;
        },
        .null => if (opts.coerce_more) return,
        .list => |l| if (opts.coerce_more) {
            const cells = l.cells();
            for (cells, 0..) |*c, i| {
                ev.coerceToString(c.get(), out, ctx, pos, "while evaluating one element of the list", opts) catch |e|
                    return ev.addTrace(e, pos, "{s}", .{err_ctx});
                if (i + 1 < cells.len) {
                    const v2 = try ev.force(c.get());
                    const empty_list = v2.kind() == .list and v2.as(value.List).len == 0;
                    if (!empty_list) try out.append(ev.gpa, ' ');
                }
            }
            return;
        },
        else => {},
    }
    const e = ev.fail(.type, pos, "cannot coerce {s} to a string: {f}", .{ v.typeOf().show(), print.short(ev, v) });
    if (err_ctx.len == 0) return e;
    return ev.addTrace(e, pos, "{s}", .{err_ctx});
}

/// `coerceToString` into a fresh arena string.
pub fn coerceToStringValue(ev: *Evaluator, v: Value, pos: Pos, err_ctx: []const u8, opts: CoerceOpts) Error!Value {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ev.gpa);
    var ctx: std.ArrayList(Ctx) = .empty;
    defer ctx.deinit(ev.gpa);
    try ev.coerceToString(v, &out, &ctx, pos, err_ctx, opts);
    return ev.mkStringCtx(out.items, ctx.items);
}

pub fn isStorePathText(ev: *const Evaluator, p: []const u8) bool {
    return std.mem.startsWith(u8, p, ev.store_dir) and (p.len == ev.store_dir.len or p[ev.store_dir.len] == '/');
}

pub fn copyPathToStore(ev: *Evaluator, path: []const u8, pos: Pos) Error![]const u8 {
    if (std.mem.endsWith(u8, path, ".drv"))
        return ev.fail(.eval, pos, "file names are not allowed to end in '.drv'", .{});
    try lint_mod.coerce.storePathRecopy(ev, path, pos);
    return store_hooks.copyPathToStore(ev, path, pos);
}

/// The `==` operator. Nix compares two fresh temporaries, so a function is
/// never equal to anything here.
pub fn eqValues(ev: *Evaluator, a_in: Value, b_in: Value, pos: Pos) Error!bool {
    const a = try ev.force(a_in);
    const b = try ev.force(b_in);
    return ev.eqForcedTop(a, b, pos);
}

/// The `==` and `!=` operators: `eqValues` and the lints on its operands.
pub fn eqOperator(ev: *Evaluator, a_in: Value, b_in: Value, pos: Pos) Error!bool {
    const a = try ev.force(a_in);
    const b = try ev.force(b_in);
    if (ev.lint_on & (lint_mod.bit(.eq_type_mismatch) | lint_mod.bit(.eq_function)) != 0) try lint_mod.coerce.eq(ev, a, b, pos);
    return ev.eqForcedTop(a, b, pos);
}

inline fn eqForcedTop(ev: *Evaluator, a: Value, b: Value, pos: Pos) Error!bool {
    // The operands are fresh temporaries in Nix, so its slot shortcut never
    // makes a function or a NaN equal here.
    if (a == b and !ev.nix_eq) switch (a.typeOf()) {
        .lambda, .float => {},
        else => return true,
    };
    return ev.eqForced(a, b, pos);
}

/// eval.cc:eqValues on two cells. Equal forced words are equal (Nix's slot
/// shortcut, kept for speed); a function only when it was one slot before
/// forcing, since two thunks can force to one function.
fn eqCells(ev: *Evaluator, x: *Cell, y: *Cell, pos: Pos) Error!bool {
    const raw_a = x.get();
    const raw_b = y.get();
    const a = try ev.forceCell(x);
    const b = try ev.forceCell(y);
    if (a == b and (raw_a == raw_b or (!ev.nix_eq and a.typeOf() != .lambda))) return true;
    return ev.eqForced(a, b, pos);
}

/// Not a call: like Nix's `eqValues`, a deep comparison is bounded by the
/// stack, not by max-call-depth.
fn eqForced(ev: *Evaluator, a: Value, b: Value, pos: Pos) Error!bool {
    const va = a.view();
    const vb = b.view();
    switch (va) {
        .int => |x| switch (vb) {
            .int => |y| return x == y,
            .float => |y| return @as(f64, @floatFromInt(x)) == y,
            else => return false,
        },
        .float => |x| switch (vb) {
            .int => |y| return x == @as(f64, @floatFromInt(y)),
            .float => |y| return x == y,
            else => return false,
        },
        .bool => |x| return vb == .bool and vb.bool == x,
        .null => return vb == .null,
        .string => |x| return vb == .string and std.mem.eql(u8, x.bytes(), vb.string.bytes()),
        .path => |x| return vb == .path and std.mem.eql(u8, x.bytes(), vb.path.bytes()),
        .list => |x| {
            if (vb != .list) return false;
            const y = vb.list;
            if (x.len != y.len) return false;
            for (x.cells(), y.cells()) |*cx, *cy| if (!try ev.eqCells(cx, cy, pos)) return false;
            return true;
        },
        .attrs => |x| {
            if (vb != .attrs) return false;
            const y = vb.attrs;
            if (try ev.isDerivation(a) and try ev.isDerivation(b)) {
                if (x.get(ev.s.outPath)) |i| if (y.get(ev.s.outPath)) |j| return ev.eqCells(&i.cell, &j.cell, pos);
            }
            if (x.len != y.len) return false;
            for (x.attrs(), y.attrs()) |*ax, *ay| {
                if (ax.sym != ay.sym or !try ev.eqCells(&ax.cell, &ay.cell, pos)) return false;
            }
            return true;
        },
        else => return false,
    }
}

/// Nix `<`, also `lessThan` and `sort`.
pub fn lessThan(ev: *Evaluator, a_in: Value, b_in: Value, pos: Pos) Error!bool {
    const a = try ev.force(a_in);
    const b = try ev.force(b_in);
    const va = a.view();
    const vb = b.view();
    switch (va) {
        .int => |x| switch (vb) {
            .int => |y| return x < y,
            .float => |y| return @as(f64, @floatFromInt(x)) < y,
            else => {},
        },
        .float => |x| switch (vb) {
            .int => |y| return x < @as(f64, @floatFromInt(y)),
            .float => |y| return x < y,
            else => {},
        },
        .string => |x| if (vb == .string) return std.mem.order(u8, x.bytes(), vb.string.bytes()) == .lt,
        .path => |x| if (vb == .path) return std.mem.order(u8, x.bytes(), vb.path.bytes()) == .lt,
        .list => |x| if (vb == .list) {
            const cx = x.cells();
            const cy = vb.list.cells();
            var i: usize = 0;
            while (true) : (i += 1) {
                if (i == cy.len) return false;
                if (i == cx.len) return true;
                if (!try ev.eqCells(&cx[i], &cy[i], pos)) return ev.lessThan(cx[i].get(), cy[i].get(), pos);
            }
        },
        else => {},
    }
    return ev.fail(.eval, pos, "cannot compare {s} with {s}; values are {f} and {f}", .{ va_show(a), va_show(b), print.short(ev, a), print.short(ev, b) });
}

fn va_show(v: Value) []const u8 {
    return v.typeOf().show();
}
