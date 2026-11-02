//! iets's own settings: the `iets.toml` files, `--iets-option` and every
//! `IETS_*` environment knob, read once into one struct. Each key, its
//! type, its default and its effect:
//! docs/reference/settings.md.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Diag = @import("diag.zig").Diag;
const Env = @import("env.zig").Env;
const errors = @import("errors.zig");
const Error = errors.Error;
const config = @import("config.zig");
const events = @import("events.zig");
const profile = @import("profile.zig");
const Log = @import("log.zig").Log;
const toml = @import("builtins/text/toml.zig");
const sys = @import("sys.zig");

/// Keys a settings file may set. Nothing else: the file is ours, so a name
/// that is not here is a mistake, not a setting for someone else.
pub const keys = [_][]const u8{
    "build-gc-root",  "builder",       "cache",       "cache-dir",   "fetch-max-size",
    "fiber-stack-mb", "fix-hashes",    "nix-bin-dir", "no-fallback", "provenance",
    "pure",           "shell-gc-root", "source-map",  "workers",
};

/// One `builder` entry: where to build, and what the place will accept.
/// The constraints are declared, not probed: the worker protocol has no op
/// that asks a daemon which platforms it builds.
pub const BuilderSpec = struct {
    url: []const u8,
    /// Platforms it builds. Empty means whatever `system` resolves to.
    systems: []const []const u8 = &.{},
    /// `requiredSystemFeatures` it satisfies.
    features: []const []const u8 = &.{},

    /// A URL with no constraints.
    pub fn bare(url: []const u8) BuilderSpec {
        return .{ .url = url };
    }
};

pub const FixHashes = enum {
    /// Asks on a terminal; elsewhere only the hint.
    ask,
    always,
    never,
};

pub const Pair = config.Override;

/// The flag every iets command accepts, in classic mode too. It is ours, so
/// it never reaches the real nix: `takeOptions` removes it from the argv a
/// fallback execs.
pub const flag = "--iets-option";

/// The settings of this process: the files, then the environment for the
/// knobs that have one. Every string lives in `arena`.
pub const Settings = struct {
    arena: std.heap.ArenaAllocator,
    /// `builder`: where derivations are realised. Empty falls back to the
    /// nix.conf `store` setting; resolve it with `builders`.
    builder: []const BuilderSpec = &.{},
    /// `source-map`: `STOREPATH=LOCALDIR` pairs (docs/explanation/provenance.md).
    source_map: []const Pair = &.{},
    /// `workers`, `IETS_WORKERS`: worker threads. Null asks the machine.
    workers: ?usize = null,
    /// `fiber-stack-mb`, `IETS_FIBER_STACK_MB`: fiber stack size in MiB.
    fiber_stack_mb: ?usize = null,
    /// `IETS_SPIN`: scans an idle searcher makes before it parks.
    spin: u32 = 2000,
    /// `IETS_SPINNERS`: idle workers that may search at once. Null is a
    /// quarter of the workers.
    spinners: ?usize = null,
    /// `IETS_HANDOFF`: queued tasks per awake worker that wake a sleeper.
    handoff: usize = 8,
    /// `IETS_FANOUT` bitmask: 1 deep, 2 coerce, 4 list builtins.
    fanout: u32 = 7,
    /// `IETS_PAR_STATS`: 1 the summary line, 2 adds the timeline.
    par_stats: u8 = 0,
    /// `IETS_STATS`: 1 the evaluator counters, 2 adds the memory census.
    stats: u8 = 0,
    /// `IETS_EVENTS`: the event groups this run watches, a bit per
    /// `events.Group`. 0 watches none, which is the normal case.
    events: u32 = 0,
    /// `IETS_EVENTS_TO`: where the events go. Null is stderr.
    events_to: ?[]const u8 = null,
    /// `IETS_PROFILE`: sample the call stack, weighed by time (`eval`) or by
    /// arena bytes (`alloc`).
    profile: ?profile.Mode = null,
    /// `IETS_PROFILE_TO`: where the folded lines go. Null is stderr.
    profile_to: ?[]const u8 = null,
    /// `IETS_PROFILE_HZ`: samples a second.
    profile_hz: u32 = 99,
    /// `cache`, `IETS_CACHE`: the tracing and IR caches.
    cache: bool = true,
    /// `cache-dir`, `IETS_CACHE_DIR`: cache root, below `--cache-dir`.
    cache_dir: ?[]const u8 = null,
    /// `IETS_IR_STATS`: one line per compiled file on stderr.
    ir_stats: bool = false,
    /// `IETS_IR_MIN`: sources below this size are not cached.
    ir_min: usize = 1024,
    /// `provenance`, `IETS_PROVENANCE`: `false` prints plain store paths.
    provenance: bool = true,
    /// `pure`: `pure-eval` for the native commands. A project file may not
    /// set it: an impure evaluation reads any path.
    pure: bool = true,
    /// `nix-bin-dir`, `IETS_NIX_BIN_DIR`: where the real Nix binaries live.
    nix_bin_dir: ?[]const u8 = null,
    /// `no-fallback`, `IETS_NO_FALLBACK`: fail instead of running the real Nix.
    no_fallback: bool = false,
    /// `shell-gc-root`: `nix-shell` and `nix develop` keep the closure they
    /// entered alive with a link in iets's roots store.
    shell_gc_root: bool = true,
    /// `build-gc-root`: `iets build` keeps the outputs it printed alive.
    build_gc_root: bool = true,
    /// `IETS_FETCHING`: set on the Nix that iets calls to fetch a flake
    /// input, so a recursive fetch is an error instead of a loop.
    fetching: bool = false,
    /// `IETS_OFFLINE`: any download is an error.
    offline: bool = false,
    /// `IETS_PROGRESS`: the status line on a terminal and the `⏵` lines on a
    /// pipe. `false` draws neither.
    progress: bool = true,
    /// `fetch-max-size`: the most bytes one download may decompress to.
    fetch_max_size: u64 = 16 << 30,
    /// `fix-hashes`: what `iets build` does with a wrong fixed-output hash.
    fix_hashes: FixHashes = .ask,
    /// `IETS_COMPLETE_MS`: the time a completion may evaluate. 0 waits.
    complete_ms: u64 = 5000,
    /// The `--iets-option` pairs this run was given, in flag order. A
    /// command that starts a second iets passes them on.
    options: []const Pair = &.{},

    pub fn deinit(s: *Settings) void {
        s.arena.deinit();
    }

    /// The environment knobs alone, for a session that read no file. A knob
    /// that does not parse is `load`'s to report, so here the whole
    /// environment is dropped instead of failing a library's session.
    pub fn default(gpa: Allocator, io: Io, env: Env, log: ?*Log) Settings {
        var d: Diag = .init(gpa);
        defer d.deinit();
        var c: Conf = .{ .gpa = gpa };
        defer c.deinit();
        return fromConf(gpa, io, &c, env, log, &d) catch fromConf(gpa, io, &c, .{}, log, &d) catch .{ .arena = .init(gpa) };
    }

    /// The user's file, then `$IETS_CONFIG`, then `overrides`, then the
    /// environment for the knobs that have a variable. Later wins.
    pub fn load(gpa: Allocator, io: Io, env: Env, overrides: []const Pair, log: ?*Log, d: *Diag) !Settings {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        return loadFrom(gpa, io, try confFile(arena.allocator(), env), overrides, env, log, d);
    }

    fn loadFrom(gpa: Allocator, io: Io, file: []const u8, overrides: []const Pair, env: Env, log: ?*Log, d: *Diag) !Settings {
        var c: Conf = .{ .gpa = gpa };
        defer c.deinit();
        if (Io.Dir.cwd().readFileAlloc(io, file, gpa, .unlimited)) |text| {
            defer gpa.free(text);
            try c.apply(text, file, true, d);
        } else |e| switch (e) {
            error.FileNotFound, error.NotDir => {},
            error.OutOfMemory => return error.OutOfMemory,
            else => return d.fail(error.Config, "{s}: {s}", .{ file, errors.ioText(e) }),
        }
        if (strEnv(env, "IETS_CONFIG")) |text| try c.apply(text, "$IETS_CONFIG", false, d);
        for (overrides) |o| try c.set(o.name, try flagValue(c.arena(), o.name, o.value), flag, false, d);
        var s = try fromConf(gpa, io, &c, env, log, d);
        errdefer s.deinit();
        const a = s.arena.allocator();
        const opts = try a.alloc(Pair, overrides.len);
        for (overrides, opts) |o, *p| p.* = .{ .name = try a.dupe(u8, o.name), .value = try a.dupe(u8, o.value) };
        s.options = opts;
        return s;
    }

    /// The `--iets-option` triples this run was given, for the argv of an
    /// iets it starts; in `a`.
    pub fn optionArgv(s: *const Settings, a: Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (s.options) |o| try out.appendSlice(a, &.{ flag, o.name, o.value });
        return out.toOwnedSlice(a);
    }

    /// The settings `c` asks for, with the environment on top.
    fn fromConf(gpa: Allocator, io: Io, c: *Conf, env: Env, log: ?*Log, d: *Diag) !Settings {
        _ = io;
        var s: Settings = .{ .arena = .init(gpa) };
        errdefer s.deinit();
        const a = s.arena.allocator();
        if (try c.get("source-map", "a list of \"STOREPATH=LOCALDIR\"", d)) |v| {
            const arr = switch (v) {
                .array => |x| x.items.items,
                else => return c.wants("source-map", "a list of \"STOREPATH=LOCALDIR\"", d),
            };
            const pairs = try a.alloc(Pair, arr.len);
            for (arr, pairs) |e, *p| {
                const str = switch (e) {
                    .string => |x| x,
                    else => return c.wants("source-map", "a list of \"STOREPATH=LOCALDIR\"", d),
                };
                const eq = std.mem.indexOfScalar(u8, str, '=') orelse return c.wants("source-map", "a list of \"STOREPATH=LOCALDIR\"", d);
                p.* = .{ .name = try a.dupe(u8, str[0..eq]), .value = try a.dupe(u8, str[eq + 1 ..]) };
            }
            s.source_map = pairs;
        }
        for (s.source_map) |p| {
            const m = sys.fs.mode(p.value, true);
            if (m == null or !sys.fs.isDir(m.?)) if (log) |l| {
                const line = try std.fmt.allocPrint(gpa, "warning: source-map: '{s}' is not a directory", .{p.value});
                defer gpa.free(line);
                l.textLine(line);
            };
        }
        if (strEnv(env, "IETS_PROFILE")) |w| {
            s.profile = profile.Mode.parse(w) orelse return d.fail(error.Config, "IETS_PROFILE: '{s}' is not 'eval' or 'alloc'", .{w});
        }
        var workers: ?usize = try num(usize, env, "IETS_WORKERS", d);
        if (workers == null) workers = try c.int(usize, "workers", d);
        if (workers == 0) return d.fail(error.Config, "workers must be 1 or more", .{});
        // A profile is read per fiber, and a fiber's stack starts at the
        // thunk it was handed, so at more than one worker the graph is a
        // pile of two-frame stacks and no shape. Profiling therefore pins
        // the worker count rather than quietly misleading.
        if (s.profile != null) {
            if (workers) |n| if (n != 1) return d.fail(error.Config, "a profile needs one worker, so workers must be 1, not {d}", .{n});
            workers = 1;
        }
        s.workers = workers;
        if (try c.get("fix-hashes", "\"ask\", \"always\" or \"never\"", d)) |v| {
            const word = switch (v) {
                .string => |x| x,
                else => "",
            };
            s.fix_hashes = std.meta.stringToEnum(FixHashes, word) orelse return c.wants("fix-hashes", "\"ask\", \"always\" or \"never\"", d);
        }
        if (try c.get("builder", builder_want, d)) |v| s.builder = try readBuilders(a, v) orelse return c.wants("builder", builder_want, d);
        s.fiber_stack_mb = try num(usize, env, "IETS_FIBER_STACK_MB", d) orelse try c.int(usize, "fiber-stack-mb", d);
        s.spin = try num(u32, env, "IETS_SPIN", d) orelse 2000;
        s.spinners = try num(usize, env, "IETS_SPINNERS", d);
        s.handoff = try num(usize, env, "IETS_HANDOFF", d) orelse 8;
        s.fanout = try num(u32, env, "IETS_FANOUT", d) orelse 7;
        s.par_stats = level(env, "IETS_PAR_STATS");
        s.stats = level(env, "IETS_STATS");
        if (strEnv(env, "IETS_EVENTS")) |names| switch (events.Group.mask(names)) {
            .ok => |m| s.events = m,
            .bad => |n| {
                var buf: [256]u8 = undefined;
                var w: std.Io.Writer = .fixed(&buf);
                events.Group.badName(&w, n) catch {};
                return d.fail(error.Config, "IETS_EVENTS: {s}", .{w.buffered()});
            },
        };
        s.events_to = if (strEnv(env, "IETS_EVENTS_TO")) |x| try a.dupe(u8, x) else null;
        s.profile_to = if (strEnv(env, "IETS_PROFILE_TO")) |x| try a.dupe(u8, x) else null;
        s.profile_hz = try num(u32, env, "IETS_PROFILE_HZ", d) orelse 99;
        s.cache = try envFlag(env, "IETS_CACHE", try c.boolean("cache", d), true, d);
        s.cache_dir = if (env.get("IETS_CACHE_DIR")) |x| try a.dupe(u8, x) else if (try c.str("cache-dir", d)) |x| try a.dupe(u8, x) else null;
        s.ir_stats = env.get("IETS_IR_STATS") != null;
        s.ir_min = try num(usize, env, "IETS_IR_MIN", d) orelse 1024;
        s.provenance = try envFlag(env, "IETS_PROVENANCE", try c.boolean("provenance", d), true, d);
        s.pure = try c.boolean("pure", d) orelse true;
        s.nix_bin_dir = if (env.get("IETS_NIX_BIN_DIR")) |x| try a.dupe(u8, x) else if (try c.str("nix-bin-dir", d)) |x| try a.dupe(u8, x) else null;
        s.no_fallback = try envFlag(env, "IETS_NO_FALLBACK", try c.boolean("no-fallback", d), false, d);
        s.shell_gc_root = try c.boolean("shell-gc-root", d) orelse true;
        s.build_gc_root = try c.boolean("build-gc-root", d) orelse true;
        s.fetching = env.get("IETS_FETCHING") != null;
        s.offline = env.get("IETS_OFFLINE") != null;
        s.progress = try envFlag(env, "IETS_PROGRESS", null, true, d);
        s.fetch_max_size = try c.int(u64, "fetch-max-size", d) orelse 16 << 30;
        s.complete_ms = try num(u64, env, "IETS_COMPLETE_MS", d) orelse 5000;
        return s;
    }
};

const builder_want = "a URL, or a list of URLs or {url, systems, features} tables";

/// `argv` without its `--iets-option name value` triples, and the pairs
/// themselves for `Settings.load`; both in `a`. Call it before any setting
/// is read.
pub fn takeOptions(a: Allocator, argv: []const []const u8, d: *Diag) !struct { rest: []const []const u8, options: []const Pair } {
    var rest: std.ArrayList([]const u8) = .empty;
    var opts: std.ArrayList(Pair) = .empty;
    // `--` ends this command's flags: what follows belongs to whatever the
    // command runs, and that may be a second iets with options of its own
    var end = argv.len;
    for (argv, 0..) |x, k| if (std.mem.eql(u8, x, "--")) {
        end = k;
        break;
    };
    var i: usize = 0;
    while (i < argv.len) {
        if (!std.mem.eql(u8, argv[i], flag) or i >= end) {
            try rest.append(a, argv[i]);
            i += 1;
            continue;
        }
        if (i + 2 >= argv.len) return d.fail(error.Usage, "'" ++ flag ++ "' wants a name and a value", .{});
        try opts.append(a, .{ .name = argv[i + 1], .value = argv[i + 2] });
        i += 3;
    }
    return .{ .rest = try rest.toOwnedSlice(a), .options = try opts.toOwnedSlice(a) };
}

/// Where a command builds: its own flag, else the `builder` setting, else
/// the nix.conf `store` setting. Never empty; in `a`.
pub fn builders(a: Allocator, flag_value: ?[]const u8, s: *const Settings, cfg: *const config.Config) ![]const BuilderSpec {
    if (flag_value) |f| {
        const specs = try splitUrls(a, f);
        if (specs.len > 0) return specs;
    }
    if (s.builder.len > 0) return s.builder;
    const one = try a.alloc(BuilderSpec, 1);
    one[0] = .bare(cfg.store());
    return one;
}

/// The user's settings file, `$XDG_CONFIG_HOME/iets/iets.toml`. It may set
/// every key; a project's `iets.toml` may not (`checkProject`). There is no
/// machine file: iets is a client, and what it builds with is the user's.
pub fn confFile(a: Allocator, env: Env) ![]const u8 {
    return std.fs.path.join(a, &.{ try config.configHome(a, env), "iets/iets.toml" });
}

/// Refuses every key of a project's `iets.toml` but `lint`. The file comes
/// with whatever repository was cloned, so it may not decide what runs
/// (`nix-bin-dir`), where sources go (`builder`) or what gets rewritten
/// (`fix-hashes`). Null is accepted; the message is in `a`.
pub fn checkProject(a: Allocator, env: Env, text: []const u8, origin: []const u8) !?[]const u8 {
    // a file that does not parse is `Conf.apply`'s to report
    var err: toml.ParseError = .{};
    const t = toml.parse(a, text, &err) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const ks = try a.dupe([]const u8, t.map.keys());
    std.mem.sort([]const u8, ks, {}, lessThan);
    const key = for (ks) |k| {
        if (!std.mem.eql(u8, k, "lint")) break k;
    } else return null;
    const why = if (contains(&keys, key))
        try std.fmt.allocPrint(a, "a repository controls this file; set it in {s}", .{try confFile(a, env)})
    else
        "it holds only [lint]";
    return try std.fmt.allocPrint(a, "{s}: '{s}' may not be set in a project file: {s}", .{ origin, key, why });
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

/// `builder` in one of its three forms: one URL, several URLs, or several
/// tables that also carry the constraints.
fn readBuilders(a: Allocator, v: toml.Node) !?[]const BuilderSpec {
    switch (v) {
        .string => |url| return try splitUrls(a, url),
        .array => |arr| {
            const out = try a.alloc(BuilderSpec, arr.items.items.len);
            for (arr.items.items, out) |e, *o| o.* = try readBuilder(a, e) orelse return null;
            return out;
        },
        else => return null,
    }
}

fn readBuilder(a: Allocator, v: toml.Node) !?BuilderSpec {
    switch (v) {
        .string => |url| return .bare(try a.dupe(u8, url)),
        .table => |t| {
            const url = switch (t.map.get("url") orelse return null) {
                .string => |u| u,
                else => return null,
            };
            return .{
                .url = try a.dupe(u8, url),
                .systems = try words(a, t, "systems") orelse return null,
                .features = try words(a, t, "features") orelse return null,
            };
        },
        else => return null,
    }
}

fn words(a: Allocator, t: *const toml.Table, key: []const u8) !?[]const []const u8 {
    const v = t.map.get(key) orelse return &.{};
    const arr = switch (v) {
        .array => |x| x.items.items,
        else => return null,
    };
    const out = try a.alloc([]const u8, arr.len);
    for (arr, out) |e, *o| o.* = switch (e) {
        .string => |s| try a.dupe(u8, s),
        else => return null,
    };
    return out;
}

/// `--builder` and `IETS_CONFIG` carry one string, so several places are
/// separated there, as nix.conf's `builders` separates machines. A URL's
/// own query string uses `&`, never `;`, so nothing is ambiguous.
fn splitUrls(a: Allocator, spec: []const u8) ![]const BuilderSpec {
    var out: std.ArrayList(BuilderSpec) = .empty;
    var it = std.mem.splitScalar(u8, spec, ';');
    while (it.next()) |raw| {
        const s = std.mem.trim(u8, raw, " \t\n\r");
        if (s.len > 0) try out.append(a, .bare(try a.dupe(u8, s)));
    }
    return out.toOwnedSlice(a);
}

/// The VALUE of `--iets-option NAME VALUE`: a TOML boolean, integer, string
/// or array when it reads as one, else the text itself, so `fix-hashes
/// always` needs no quotes. Bare text for `source-map` is a
/// whitespace-separated list.
fn flagValue(a: Allocator, name: []const u8, value: []const u8) !toml.Node {
    const text = try std.fmt.allocPrint(a, "v = {s}", .{value});
    var err: toml.ParseError = .{};
    const parsed: ?*toml.Table = toml.parse(a, text, &err) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Syntax => null,
    };
    if (parsed) |t| if (t.map.get("v")) |v| switch (v) {
        .boolean, .integer, .string, .array => return v,
        else => {},
    };
    if (std.mem.eql(u8, name, "source-map")) {
        const arr = try a.create(toml.Array);
        arr.* = .{ .of_tables = false };
        var it = std.mem.tokenizeAny(u8, value, " \t\n\r");
        while (it.next()) |w| try arr.items.append(a, .{ .string = w });
        return .{ .array = arr };
    }
    return .{ .string = value };
}

/// What the settings sources said: each key's TOML value and where it was
/// set, for an error message. A later source replaces a key, except
/// `source-map`, whose entries add up.
const Conf = struct {
    gpa: Allocator,
    arena_: ?*std.heap.ArenaAllocator = null,
    at: std.StringArrayHashMapUnmanaged(struct { v: toml.Node, at: []const u8 }) = .empty,

    fn arena(c: *Conf) Allocator {
        if (c.arena_ == null) {
            const a = c.gpa.create(std.heap.ArenaAllocator) catch @panic("out of memory");
            a.* = .init(c.gpa);
            c.arena_ = a;
        }
        return c.arena_.?.allocator();
    }

    fn deinit(c: *Conf) void {
        c.at.deinit(c.gpa);
        if (c.arena_) |a| {
            a.deinit();
            c.gpa.destroy(a);
        }
    }

    fn apply(c: *Conf, text: []const u8, at: []const u8, file: bool, d: *Diag) !void {
        const a = c.arena();
        const own = try a.dupe(u8, text);
        var err: toml.ParseError = .{};
        const t = toml.parse(a, own, &err) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Syntax => {
                var buf: std.Io.Writer.Allocating = .init(c.gpa);
                defer buf.deinit();
                try toml.renderError(&buf.writer, own, err);
                return d.fail(error.Config, "{s}: {s}", .{ at, std.mem.trimEnd(u8, buf.written(), " \t\n\r") });
            },
        };
        const at_own = try a.dupe(u8, at);
        // `toml::Table` is a sorted map: the first unknown key in byte order
        // is the one reported.
        const ks = try a.dupe([]const u8, t.map.keys());
        std.mem.sort([]const u8, ks, {}, lessThan);
        for (ks) |k| try c.set(k, t.map.get(k).?, at_own, file, d);
    }

    /// `file` is a settings file, where a `[lint]` table is the lint
    /// configuration's to read (`lint.Config.resolve`).
    fn set(c: *Conf, name: []const u8, value: toml.Node, at: []const u8, file: bool, d: *Diag) !void {
        if (std.mem.eql(u8, name, "lint") and file) return;
        if (!contains(&keys, name)) return d.fail(error.Config, "unknown iets setting '{s}' in {s}", .{ name, at });
        const a = c.arena();
        var v = value;
        var where = at;
        if (c.at.fetchOrderedRemove(name)) |old| {
            if (std.mem.eql(u8, name, "source-map") and old.value.v == .array and value == .array) {
                const arr = try a.create(toml.Array);
                arr.* = .{ .of_tables = false };
                try arr.items.appendSlice(a, old.value.v.array.items.items);
                try arr.items.appendSlice(a, value.array.items.items);
                v = .{ .array = arr };
                where = try std.fmt.allocPrint(a, "{s} and {s}", .{ old.value.at, at });
            }
        }
        try c.at.put(c.gpa, name, .{ .v = v, .at = where });
    }

    fn get(c: *Conf, name: []const u8, want: []const u8, d: *Diag) !?toml.Node {
        _ = want;
        _ = d;
        const e = c.at.get(name) orelse return null;
        return e.v;
    }

    /// The error for a value of the wrong type.
    fn wants(c: *Conf, name: []const u8, want: []const u8, d: *Diag) Error {
        const e = c.at.get(name).?;
        var buf: std.Io.Writer.Allocating = .init(c.gpa);
        defer buf.deinit();
        showValue(&buf.writer, e.v) catch {};
        return d.fail(error.Config, "iets setting '{s}' wants {s}, got {s} in {s}", .{ name, want, buf.written(), e.at });
    }

    fn boolean(c: *Conf, name: []const u8, d: *Diag) !?bool {
        const v = c.at.get(name) orelse return null;
        return switch (v.v) {
            .boolean => |b| b,
            else => c.wants(name, "true or false", d),
        };
    }

    fn int(c: *Conf, comptime T: type, name: []const u8, d: *Diag) !?T {
        const v = c.at.get(name) orelse return null;
        return switch (v.v) {
            .integer => |i| std.math.cast(T, i) orelse c.wants(name, "an integer", d),
            else => c.wants(name, "an integer", d),
        };
    }

    fn str(c: *Conf, name: []const u8, d: *Diag) !?[]const u8 {
        const v = c.at.get(name) orelse return null;
        return switch (v.v) {
            .string => |s| s,
            else => c.wants(name, "a string", d),
        };
    }
};

/// A TOML value as the toml crate's `Display` shows it.
fn showValue(w: *std.Io.Writer, v: toml.Node) !void {
    switch (v) {
        .string => |s| try showString(w, s),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| {
            if (std.math.isNan(f)) return w.writeAll("nan");
            if (std.math.isInf(f)) return w.writeAll(if (f < 0) "-inf" else "inf");
            var buf: [64]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{d}", .{f});
            try w.writeAll(s);
            if (std.mem.indexOfAny(u8, s, ".e") == null) try w.writeAll(".0");
        },
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .datetime => |dt| try toml.parser.displayDatetime(w, dt),
        .invalid => unreachable,
        .array => |arr| {
            try w.writeByte('[');
            for (arr.items.items, 0..) |x, i| {
                if (i > 0) try w.writeAll(", ");
                try showValue(w, x);
            }
            try w.writeByte(']');
        },
        .table => |t| {
            try w.writeAll("{ ");
            for (t.map.keys(), t.map.values(), 0..) |k, x, i| {
                if (i > 0) try w.writeAll(", ");
                try w.print("{s} = ", .{k});
                try showValue(w, x);
            }
            try w.writeAll(" }");
        },
    }
}

/// toml_edit's choice: a literal string when the text has a quote or a
/// backslash and no apostrophe or control character, else a basic one.
fn showString(w: *std.Io.Writer, s: []const u8) !void {
    const has_special = std.mem.indexOfAny(u8, s, "\"\\") != null;
    const has_ctl = for (s) |c| {
        if (c < 0x20 or c == 0x7f) break true;
    } else false;
    if (has_special and !has_ctl and std.mem.indexOfScalar(u8, s, '\'') == null) return w.print("'{s}'", .{s});
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        '\r' => try w.writeAll("\\r"),
        0x08 => try w.writeAll("\\b"),
        0x0c => try w.writeAll("\\f"),
        else => if (c < 0x20 or c == 0x7f) try w.print("\\u{X:0>4}", .{c}) else try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// A non-empty variable.
fn strEnv(env: Env, name: []const u8) ?[]const u8 {
    return env.nonEmpty(name);
}

/// A number knob: decimal digits with an optional leading `+`, the form
/// Rust iets accepts.
fn num(comptime T: type, env: Env, name: []const u8, d: *Diag) !?T {
    const v = env.get(name) orelse return null;
    const body = if (v.len > 0 and v[0] == '+') v[1..] else v;
    const ok = body.len > 0 and for (body) |c| {
        if (!std.ascii.isDigit(c)) break false;
    } else true;
    if (!ok) return d.fail(error.Config, "{s}: '{s}' is not a number", .{ name, v });
    return std.fmt.parseInt(T, body, 10) catch d.fail(error.Config, "{s}: '{s}' is not a number", .{ name, v });
}

/// A level knob: unset is 0, `2` is 2, any other value is 1, so a knob set
/// as a plain on/off switch still turns on.
fn level(env: Env, name: []const u8) u8 {
    const v = env.get(name) orelse return 0;
    return if (std.mem.eql(u8, v, "2")) 2 else 1;
}

/// A Boolean `IETS_*` variable, parsed the way nix.conf parses a Boolean.
fn envBool(name: []const u8, v: []const u8, d: *Diag) Error!bool {
    return config.parseBoolQuiet(v) orelse d.fail(error.Config, "{s}: '{s}' is not true or false", .{ name, v });
}

/// The environment wins over the file, which wins over `default`. The value
/// is a nix.conf Boolean, so `IETS_CACHE=false` turns the cache off.
fn envFlag(env: Env, name: []const u8, file: ?bool, default_: bool, d: *Diag) Error!bool {
    if (env.get(name)) |v| return envBool(name, v, d);
    return file orelse default_;
}

const testing = std.testing;
const fromPairs = @import("env.zig").fromPairs;

const Fx = struct {
    t: testing.TmpDir,
    dir: [:0]u8,
    file: []u8,

    /// Where the user file goes in a fresh directory. Nothing writes it yet.
    fn init() !Fx {
        var t = testing.tmpDir(.{});
        try t.dir.createDirPath(testing.io, "user");
        const dir = try t.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        return .{ .t = t, .dir = dir, .file = try std.fs.path.join(testing.allocator, &.{ dir, "user/iets.toml" }) };
    }

    fn write(f: *Fx, text: []const u8) !void {
        try f.t.dir.writeFile(testing.io, .{ .sub_path = "user/iets.toml", .data = text });
    }

    fn deinit(f: *Fx) void {
        testing.allocator.free(f.file);
        testing.allocator.free(f.dir);
        f.t.cleanup();
    }
};

fn loadText(text: []const u8, d: *Diag) !Settings {
    var c: Conf = .{ .gpa = testing.allocator };
    defer c.deinit();
    try c.apply(text, "t.toml", true, d);
    return Settings.fromConf(testing.allocator, testing.io, &c, .{}, null, d);
}

fn expectErr(text: []const u8, want: []const u8) !void {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    if (loadText(text, &d)) |s| {
        var x = s;
        x.deinit();
        return error.TestExpectedError;
    } else |_| {}
    if (std.mem.indexOf(u8, d.message(), want) == null) {
        std.debug.print("{s}\n", .{d.message()});
        return error.TestUnexpectedResult;
    }
    try testing.expect(std.mem.endsWith(u8, d.message(), "in t.toml"));
}

test "each source wins over the one before" {
    var f: Fx = try .init();
    defer f.deinit();
    try f.write("builder = \"user\"\nworkers = 2\nfiber-stack-mb = 2\ncache = false\nfetch-max-size = 1\n");
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var m = try fromPairs(testing.allocator, &.{ .{ "IETS_CONFIG", "builder = \"inline\"\nworkers = 3\n" }, .{ "IETS_WORKERS", "5" }, .{ "IETS_CACHE", "1" } });
    defer m.deinit();
    {
        var s = try Settings.loadFrom(testing.allocator, testing.io, f.file, &.{.{ .name = "builder", .value = "flag" }}, .process(&m), null, &d);
        defer s.deinit();
        try testing.expectEqual(1, s.builder.len);
        try testing.expectEqualStrings("flag", s.builder[0].url);
        try testing.expectEqual(5, s.workers.?);
        try testing.expectEqual(2, s.fiber_stack_mb.?);
        try testing.expectEqual(1, s.fetch_max_size);
        try testing.expect(s.cache);
    }
    {
        var s = try Settings.loadFrom(testing.allocator, testing.io, f.file, &.{}, .{}, null, &d);
        defer s.deinit();
        try testing.expectEqualStrings("user", s.builder[0].url);
        try testing.expectEqual(2, s.workers.?);
        try testing.expect(!s.cache);
    }
    var inline_ = try fromPairs(testing.allocator, &.{.{ "IETS_CONFIG", "workers = 3" }});
    defer inline_.deinit();
    {
        var s = try Settings.loadFrom(testing.allocator, testing.io, f.file, &.{.{ .name = "workers", .value = "4" }}, .process(&inline_), null, &d);
        defer s.deinit();
        try testing.expectEqual(4, s.workers.?);
    }
    var s = try Settings.loadFrom(testing.allocator, testing.io, f.file, &.{}, .process(&inline_), null, &d);
    defer s.deinit();
    try testing.expectEqual(3, s.workers.?);
}

test "source-map adds up and every other key replaces" {
    var f: Fx = try .init();
    defer f.deinit();
    try f.write("source-map = [\"/nix/store/a=/a\"]\n");
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var m = try fromPairs(testing.allocator, &.{.{ "IETS_CONFIG", "source-map = [\"/nix/store/b=/b\"]" }});
    defer m.deinit();
    {
        var s = try Settings.loadFrom(testing.allocator, testing.io, f.file, &.{.{ .name = "source-map", .value = "/nix/store/c=/c /nix/store/d=/d" }}, .process(&m), null, &d);
        defer s.deinit();
        const want = [_][]const u8{ "/nix/store/a", "/nix/store/b", "/nix/store/c", "/nix/store/d" };
        try testing.expectEqual(want.len, s.source_map.len);
        for (want, s.source_map) |w, p| try testing.expectEqualStrings(w, p.name);
    }
    try f.write("source-map = [\"no-equals-sign\"]\n");
    try testing.expectError(error.Config, Settings.loadFrom(testing.allocator, testing.io, f.file, &.{}, .{}, null, &d));
    try testing.expect(std.mem.indexOf(u8, d.message(), "'source-map' wants a list") != null);
    try testing.expect(std.mem.indexOf(u8, d.message(), "user/iets.toml") != null);
}

test "builder reads all three forms" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    {
        var s = try loadText("builder = \"daemon\"", &d);
        defer s.deinit();
        try testing.expectEqualStrings("daemon", s.builder[0].url);
    }
    {
        var s = try loadText("builder = [\"daemon\", \"ssh-ng://bld1\"]", &d);
        defer s.deinit();
        try testing.expectEqual(2, s.builder.len);
        try testing.expectEqualStrings("ssh-ng://bld1", s.builder[1].url);
    }
    var s = try loadText("builder = [{ url = \"ssh-ng://bld1\", systems = [\"aarch64-linux\"], features = [\"kvm\"] }]", &d);
    defer s.deinit();
    try testing.expectEqualStrings("ssh-ng://bld1", s.builder[0].url);
    try testing.expectEqualStrings("aarch64-linux", s.builder[0].systems[0]);
    try testing.expectEqualStrings("kvm", s.builder[0].features[0]);
}

test "a flag carries several places separated by a semicolon" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = try splitUrls(arena.allocator(), "daemon ; ssh-ng://bld1");
    try testing.expectEqual(2, a.len);
    try testing.expectEqualStrings("daemon", a[0].url);
    try testing.expectEqualStrings("ssh-ng://bld1", a[1].url);
    // A URL's own query string uses `&`, so it survives the split whole.
    const b = try splitUrls(arena.allocator(), "grpc://farm:50051?system=aarch64-linux&insecure=1");
    try testing.expectEqualStrings("grpc://farm:50051?system=aarch64-linux&insecure=1", b[0].url);
}

test "a missing file is skipped and the defaults hold" {
    var f: Fx = try .init();
    defer f.deinit();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var s = try Settings.loadFrom(testing.allocator, testing.io, f.file, &.{}, .{}, null, &d);
    defer s.deinit();
    try testing.expectEqual(0, s.builder.len);
    try testing.expect(s.workers == null);
    try testing.expectEqual(16 << 30, s.fetch_max_size);
    try testing.expectEqual(FixHashes.ask, s.fix_hashes);
    try testing.expect(s.cache and s.provenance and s.shell_gc_root and s.build_gc_root);
    try testing.expect(s.pure);
    try testing.expect(!s.no_fallback);
}

test "the user file turns purity off" {
    var f: Fx = try .init();
    defer f.deinit();
    try f.write("pure = false\n");
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    {
        var s = try Settings.loadFrom(testing.allocator, testing.io, f.file, &.{}, .{}, null, &d);
        defer s.deinit();
        try testing.expect(!s.pure);
    }
    var s = try Settings.loadFrom(testing.allocator, testing.io, f.file, &.{.{ .name = "pure", .value = "true" }}, .{}, null, &d);
    defer s.deinit();
    try testing.expect(s.pure);
}

test "a project file holds lint and nothing else" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = try fromPairs(testing.allocator, &.{.{ "HOME", "/home/u" }});
    defer m.deinit();
    const env: Env = .process(&m);
    try testing.expect(try checkProject(a, env, "[lint]\npath-copy = \"warn\"\n", "/repo/iets.toml") == null);
    try testing.expect(try checkProject(a, env, "", "/repo/iets.toml") == null);
    for (keys) |k| {
        const e = (try checkProject(a, env, try std.fmt.allocPrint(a, "{s} = true\n[lint]\n", .{k}), "/repo/iets.toml")).?;
        try testing.expect(std.mem.startsWith(u8, e, try std.fmt.allocPrint(a, "/repo/iets.toml: '{s}' may not be set in a project file", .{k})));
        try testing.expect(std.mem.indexOf(u8, e, "/home/u/.config/iets/iets.toml") != null);
    }
    const e = (try checkProject(a, env, "nope = 1\n", "/repo/iets.toml")).?;
    try testing.expect(std.mem.endsWith(u8, e, "'nope' may not be set in a project file: it holds only [lint]"));
    try testing.expect(try checkProject(a, env, "lint = [\n", "/repo/iets.toml") == null);
}

test "a settings file may hold lint and the other sources may not" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var s = try loadText("[lint]\npath-copy = \"warn\"\n", &d);
    s.deinit();
    var c: Conf = .{ .gpa = testing.allocator };
    defer c.deinit();
    try testing.expectError(error.Config, c.apply("[lint]\n", "$IETS_CONFIG", false, &d));
    try testing.expect(std.mem.indexOf(u8, d.message(), "setting 'lint' in $IETS_CONFIG") != null);
}

test "unknown key names the file" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    try testing.expectError(error.Config, loadText("builder = \"daemon\"\nnope = 1\n", &d));
    try testing.expectEqualStrings("unknown iets setting 'nope' in t.toml", d.message());
    try testing.expectError(error.Config, loadText("extra-source-map = []\n", &d));
    try testing.expect(std.mem.indexOf(u8, d.message(), "'extra-source-map'") != null);
}

test "a wrong type names the key and the file" {
    try expectErr("workers = \"four\"", "'workers' wants an integer, got \"four\" in t.toml");
    try expectErr("workers = -1", "'workers' wants an integer, got -1");
    try expectErr("cache = \"no\"", "'cache' wants true or false, got \"no\"");
    try expectErr("no-fallback = 1", "'no-fallback' wants true or false, got 1");
    try expectErr("builder = 4", "'builder' wants a URL, or a list of URLs or {url, systems, features} tables, got 4");
    try expectErr("fix-hashes = \"yes\"", "'fix-hashes' wants \"ask\", \"always\" or \"never\"");
    try expectErr("source-map = \"/nix/store/a=/a\"", "'source-map' wants a list");
    try expectErr("builder = [1, \"a\"]", "got [1, \"a\"] in");
    try expectErr("builder = { url = 1, x = [true] }", "got { url = 1, x = [true] } in");
    try expectErr("workers = 'a\"b\\c'", "got 'a\"b\\c' in");
}

test "a syntax error names the file first" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    try testing.expectError(error.Config, loadText("workers = ", &d));
    try testing.expect(std.mem.startsWith(u8, d.message(), "t.toml: TOML parse error at line 1, column 11\n  |\n1 | workers = \n  |           ^\n"));
    try testing.expectError(error.Config, loadText("workers = 1\nworkers = 2", &d));
    try testing.expectEqualStrings("t.toml: TOML parse error at line 2, column 1\n  |\n2 | workers = 2\n  | ^^^^^^^\nduplicate key", d.message());
}

test "the flag value is toml when it reads as toml" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(4, (try flagValue(a, "workers", "4")).integer);
    try testing.expectEqual(false, (try flagValue(a, "cache", "false")).boolean);
    try testing.expectEqualStrings("always", (try flagValue(a, "fix-hashes", "always")).string);
    try testing.expectEqualStrings("always", (try flagValue(a, "fix-hashes", "\"always\"")).string);
    try testing.expectEqualStrings("ssh-ng://bld1", (try flagValue(a, "builder", "ssh-ng://bld1")).string);
    try testing.expectEqualStrings("inf", (try flagValue(a, "builder", "inf")).string);
    const l1 = try flagValue(a, "source-map", "[\"/nix/store/a=/a\"]");
    const l2 = try flagValue(a, "source-map", "/nix/store/a=/a");
    try testing.expectEqualStrings(l1.array.items.items[0].string, l2.array.items.items[0].string);
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    try testing.expectError(error.Config, Settings.loadFrom(testing.allocator, testing.io, "/nonexistent", &.{.{ .name = "workers", .value = "four" }}, .{}, null, &d));
    try testing.expect(std.mem.indexOf(u8, d.message(), "'workers' wants an integer") != null);
    try testing.expect(std.mem.endsWith(u8, d.message(), "in " ++ flag));
    var s = try Settings.loadFrom(testing.allocator, testing.io, "/nonexistent", &.{.{ .name = "shell-gc-root", .value = "false" }}, .{}, null, &d);
    defer s.deinit();
    try testing.expect(!s.shell_gc_root);
}

test "the flag leaves the argv" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const t = try takeOptions(arena.allocator(), &.{ "--parse", flag, "workers", "2", "-E", "1" }, &d);
    try testing.expectEqual(3, t.rest.len);
    try testing.expectEqualStrings("-E", t.rest[1]);
    try testing.expectEqualStrings("workers", t.options[0].name);
    try testing.expectEqualStrings("2", t.options[0].value);
    try testing.expectError(error.Usage, takeOptions(arena.allocator(), &.{ flag, "workers" }, &d));
    const after = try takeOptions(arena.allocator(), &.{ "x", "--", flag, "a", "b" }, &d);
    try testing.expectEqual(5, after.rest.len);
}

test "the environment wins over the file" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    try testing.expect(try envFlag(.{}, "X", null, true, &d));
    try testing.expect(!try envFlag(.{}, "X", false, true, &d));
    try testing.expect(try envFlag(.{}, "X", true, false, &d));
    var zero = try fromPairs(testing.allocator, &.{.{ "X", "0" }});
    defer zero.deinit();
    try testing.expect(!try envFlag(.process(&zero), "X", true, true, &d));
    for ([_][]const u8{ "0", "no", "false" }) |off| try testing.expect(!try envBool("X", off, &d));
    for ([_][]const u8{ "1", "yes", "true" }) |on| try testing.expect(try envBool("X", on, &d));
    for ([_][]const u8{ "", "maybe", "2" }) |bad| {
        try testing.expectError(error.Config, envBool("X", bad, &d));
        const want = try std.fmt.allocPrint(testing.allocator, "X: '{s}' is not true or false", .{bad});
        defer testing.allocator.free(want);
        try testing.expectEqualStrings(want, d.message());
    }
    var abc = try fromPairs(testing.allocator, &.{.{ "N", "abc" }});
    defer abc.deinit();
    try testing.expectError(error.Config, num(usize, .process(&abc), "N", &d));
    try testing.expectEqualStrings("N: 'abc' is not a number", d.message());
}

test "the flag pairs are kept for a second iets" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var s = try Settings.loadFrom(testing.allocator, testing.io, "/nonexistent", &.{ .{ .name = "workers", .value = "2" }, .{ .name = "cache-dir", .value = "/d" } }, .{}, null, &d);
    defer s.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const argv = try s.optionArgv(arena.allocator());
    const want = [_][]const u8{ flag, "workers", "2", flag, "cache-dir", "/d" };
    try testing.expectEqual(want.len, argv.len);
    for (want, argv) |w, g| try testing.expectEqualStrings(w, g);
    var plain: Settings = .default(testing.allocator, testing.io, .{}, null);
    defer plain.deinit();
    try testing.expectEqual(0, plain.options.len);
}

test "a profile pins one worker, and events and profile names are checked" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var two = try fromPairs(testing.allocator, &.{ .{ "IETS_PROFILE", "eval" }, .{ "IETS_WORKERS", "2" } });
    defer two.deinit();
    try testing.expectError(error.Config, Settings.loadFrom(testing.allocator, testing.io, "/nonexistent", &.{}, .process(&two), null, &d));
    try testing.expectEqualStrings("a profile needs one worker, so workers must be 1, not 2", d.message());
    var one = try fromPairs(testing.allocator, &.{.{ "IETS_PROFILE", "alloc" }});
    defer one.deinit();
    {
        var s = try Settings.loadFrom(testing.allocator, testing.io, "/nonexistent", &.{}, .process(&one), null, &d);
        defer s.deinit();
        try testing.expectEqual(1, s.workers.?);
        try testing.expectEqual(profile.Mode.bytes, s.profile.?);
    }
    var ev = try fromPairs(testing.allocator, &.{.{ "IETS_EVENTS", "store,stor" }});
    defer ev.deinit();
    try testing.expectError(error.Config, Settings.loadFrom(testing.allocator, testing.io, "/nonexistent", &.{}, .process(&ev), null, &d));
    try testing.expect(std.mem.startsWith(u8, d.message(), "IETS_EVENTS: 'stor' is not an event group (all, syntax"));
    var zero = try fromPairs(testing.allocator, &.{.{ "IETS_WORKERS", "0" }});
    defer zero.deinit();
    try testing.expectError(error.Config, Settings.loadFrom(testing.allocator, testing.io, "/nonexistent", &.{}, .process(&zero), null, &d));
    try testing.expectEqualStrings("workers must be 1 or more", d.message());
}

test "the file is the user's" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect(std.mem.endsWith(u8, try confFile(arena.allocator(), .{}), "iets/iets.toml"));
}
