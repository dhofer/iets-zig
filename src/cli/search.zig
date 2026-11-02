//! `nix search` and `iets search`: the package walk of Nix's
//! `src/nix/search.cc` over an index the tracing cache keeps between runs
//! (docs/reference/commands.md).
//!
//! `classicMain` is `nix search` for the classic dispatch: a command line it
//! cannot take falls back to the real nix there.

const std = @import("std");
const text = @import("../syntax/text.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const cli = @import("../cli.zig");
const help = @import("help.zig");
const args_mod = @import("args.zig");
const api = @import("../api.zig");
const Evaluator = @import("../eval/Evaluator.zig");
const import_ = @import("../eval/import.zig");
const print = @import("../eval/print.zig");
const value = @import("../runtime/value.zig");
const Value = value.Value;
const Attrs = value.Attrs;
const regex = @import("../builtins/text/regex.zig");
const strings = @import("../builtins/strings.zig");
const lint = @import("../lint.zig");
const log = @import("../log.zig");
const Report = log.Report;
const Session = @import("../session.zig").Session;
const classic = @import("classic/mod.zig");
const Cmd = classic.Cmd;
const Stop = classic.Stop;
const sysfs = @import("../sys/fs.zig");

const bold = "\x1b[0;1m";
const green = "\x1b[32;1m";
const normal = "\x1b[0m";

/// One package: what the index keeps, what the output prints, and what the
/// regexes match on.
pub const Entry = struct {
    path: []const u8,
    pname: []const u8,
    version: []const u8,
    desc: []const u8,
};

const Search = struct {
    c: classic.Common = .{},
    json: bool = false,
    /// `--pretty`/`--no-pretty`; the default is a terminal on stdout.
    pretty: ?bool = null,
    expr: ?[]const u8 = null,
    file: ?[]const u8 = null,
    /// The attribute path inside `--expr`/`--file`, else the flake reference.
    what: ?[]const u8 = null,
    regexes: []const []const u8 = &.{},
    exclude: std.ArrayList([]const u8) = .empty,
    native: bool = false,
    timings: bool = false,
    /// `--no-tracing-cache`, `--no-ir-cache`, `--no-cache`, `--cache-dir`
    /// and `--workers`, the block every evaluating command shares;
    /// `keyArgs` carries them on.
    cache: api.EvalArgs = .{},
};

/// `iets search [INSTALLABLE] REGEX...` (docs/reference/commands.md).
pub fn cmd(c: *const cli.Ctx, argv: []const []const u8) u8 {
    var k: Cmd = .init(c, "nix", argv);
    var se = parse(&k, argv, true) catch |e| return switch (e) {
        error.Fallback => help.argError(c.s, k.why),
        error.Exit => k.code,
        error.OutOfMemory => 1,
    };
    // The default installable is `<nixpkgs>`: iets has no flake registry, so
    // `nix search nixpkgs` has nothing to resolve.
    if (se.what) |w| {
        if (!args_mod.isFlakeRef(c.s.io, w)) {
            se.file = w;
            se.what = null;
        }
    } else if (se.expr == null and se.file == null) se.file = "<nixpkgs>";
    // natively, what classic mode falls back for is unsupported
    return run(&k, &se) catch |e| switch (e) {
        error.Fallback => (Report{ .code = "unsupported", .raw = k.why }).emit(&c.s.log),
        error.Exit => k.code,
        error.OutOfMemory => 1,
    };
}

/// `nix search INSTALLABLE REGEX...`; `rest` is the command line without
/// the subcommand word.
pub fn classicMain(k: *Cmd, rest: []const []const u8) Stop!u8 {
    var se = try parse(k, rest, false);
    return run(k, &se);
}

/// The cache flags every evaluating command shares; they are iets's own,
/// so a classic `nix search` keeps rejecting them and falls back.
const cache_flags = [_]struct { []const u8, bool }{
    .{ "--no-tracing-cache", false }, .{ "--no-ir-cache", false }, .{ "--no-cache", false },
    .{ "--workers", true },           .{ "--cache-dir", true },
};

fn parse(k: *Cmd, argv: []const []const u8, native: bool) Stop!Search {
    const eql = std.mem.eql;
    var se: Search = .{ .native = native };
    se.cache = .{ .no_tracing_cache = !k.s.settings.cache, .no_ir_cache = !k.s.settings.cache };
    var pos: std.ArrayList([]const u8) = .empty;
    var a: classic.Argv = .{ .k = k, .all = argv };
    while (a.i < argv.len) : (a.i += 1) {
        const t = argv[a.i];
        if (eql(u8, t, "--json")) {
            se.json = true;
        } else if (eql(u8, t, "--pretty")) {
            se.pretty = true;
        } else if (eql(u8, t, "--no-pretty")) {
            se.pretty = false;
        } else if (eql(u8, t, "-e") or eql(u8, t, "--exclude")) {
            try se.exclude.append(k.arena, try a.value(t));
        } else if (eql(u8, t, "--expr")) {
            se.expr = try a.value(t);
        } else if (eql(u8, t, "-f") or eql(u8, t, "--file")) {
            se.file = try a.value(t);
        } else if (native and eql(u8, t, "--timings")) {
            se.timings = true;
        } else if (native and try cacheFlag(k, &a, &se.cache, t)) {
            // taken
        } else if (!try classic.nix.globalFlag(&se.c, &a, t)) {
            if (t.len > 0 and t[0] == '-' and !eql(u8, t, "-")) return k.fallBack("'{s}' is not implemented", .{t});
            try pos.append(k.arena, t);
        }
    }
    // The first argument is the installable; natively only when it names
    // one, so that `iets search hello` searches nixpkgs.
    const takes = pos.items.len > 0 and
        (!native or (se.expr == null and se.file == null and looksInstallable(k, pos.items[0])));
    var rest = pos.items;
    if (takes) {
        se.what = rest[0];
        rest = rest[1..];
    }
    se.regexes = rest;
    return se;
}

/// One of `cache_flags`, its value taken by `Argv`; a bad one is a
/// usage error.
fn cacheFlag(k: *Cmd, a: *classic.Argv, ea: *api.EvalArgs, t: []const u8) Stop!bool {
    for (cache_flags) |f| if (std.mem.eql(u8, f[0], t)) {
        var words: [2][]const u8 = .{ t, "" };
        if (f[1]) words[1] = try a.value(t);
        var aa: args_mod.Args = .{ .s = k.s, .arena = k.arena, .cmd = "search", .argv = words[0..if (f[1]) 2 else 1] };
        _ = args_mod.cacheFlag(&aa, ea, t) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return k.exit(help.argError(k.s, aa.msg)),
        };
        return true;
    };
    return false;
}

/// A first argument that names an installable rather than a regex: a flake
/// reference, `<name>`, or a path that is there.
fn looksInstallable(k: *Cmd, w: []const u8) bool {
    if (args_mod.isFlakeRef(k.s.io, w)) return true;
    if (w.len >= 2 and w[0] == '<' and w[w.len - 1] == '>') return true;
    _ = std.Io.Dir.cwd().statFile(k.s.io, w, .{}) catch return false;
    return true;
}

fn run(k: *Cmd, se: *Search) Stop!u8 {
    const s = k.s;
    const arena = k.arena;
    if (se.regexes.len == 0)
        return k.exit(help.argError(s, "Must provide at least one regex! To match all packages, use 'nix search <installable> ^'."));
    var code: u8 = 1;
    const res = compileAll(s, arena, se.regexes, &code) orelse return k.exit(code);
    const exclude = compileAll(s, arena, se.exclude.items, &code) orelse return k.exit(code);
    const st = try classic.nix.nixSettings(k, &se.c, se.file != null, true);
    const ea = try arena.create(api.EvalArgs);
    ea.* = try classic.evalArgs(k, &se.c, st.cfg);
    ea.no_ir_cache = se.cache.no_ir_cache;
    ea.workers = se.cache.workers;
    var r = try classic.run(k, &se.c, st.cfg, ea);
    r.keep_aterm = false;
    r.keep_site = false;
    const cwd = try classic.cwd(k);
    // The cache key names the file, so `<nixpkgs>` and a directory become
    // the file an import would read. The lookup has an evaluator of its own.
    if (se.file) |f| {
        var look: Lookup = .{ .file = f, .cwd = cwd, .a = arena };
        const rc = try classic.ran(k, r.go(&look, Lookup.go));
        if (rc != 0) return k.exit(rc);
        se.file = look.out;
    }
    const key = keyArgs(se);
    classic.openCache(k, &r, &key, "search", &.{});
    defer if (r.cache) |tc| tc.deinit();
    var index: []const Entry = &.{};
    var answered = false;
    if (r.cache != null) {
        const store = try classic.inputStore(k, ea.cache_dir);
        defer store.deinit();
        if (classic.hitResult(k, &r, store)) |bytes| if (try decode(arena, bytes)) |ix| {
            r.cache.?.replayWarnings() catch {};
            index = ix;
            answered = true;
        };
    }
    if (!answered) {
        var b: Build = .{ .se = se, .cwd = cwd, .cache = r.cache, .a = arena };
        r.keep_aterm = r.cache != null;
        const rc = try classic.ran(k, r.go(&b, Build.go));
        if (rc != 0) return k.exit(rc);
        index = b.index.items;
    }
    var out: Writer.Allocating = .init(arena);
    const results = showResults(&out.writer, index, res, exclude, se, s) catch |e| switch (e) {
        error.BadUtf8 => return k.exit((Report{ .code = "eval", .raw = "JSON serialization error: invalid UTF-8 byte in string" }).emit(&s.log)),
        else => return error.OutOfMemory,
    };
    if (out.written().len > 0) try classic.out(k, out.written());
    if (results == 0 and !se.json)
        return k.exit((Report{ .code = "no-results", .raw = "no results for the given search term(s)!", .hint = "use fewer or shorter regexes" }).emit(&s.log));
    return 0;
}

/// `lookupFileArg` and `entry_file`: `<name>` through the search path, a
/// directory to its `default.nix`.
const Lookup = struct {
    file: []const u8,
    cwd: []const u8,
    a: Allocator,
    out: []const u8 = "",

    fn go(l: *Lookup, ev: *Evaluator) !u8 {
        const f = l.file;
        const a = l.a;
        var p = try classic.lookupFileArg(ev, a, f, l.cwd);
        if (sysfs.mode(p, true)) |m| if (sysfs.isDirMode(m)) {
            p = try std.mem.concat(a, u8, &.{ p, "/default.nix" });
        };
        l.out = try a.dupe(u8, p);
        return 0;
    }
};

const Build = struct {
    se: *const Search,
    cwd: []const u8,
    cache: ?*api.cache.Cache,
    a: Allocator,
    index: std.ArrayList(Entry) = .empty,

    fn go(b: *Build, ev: *Evaluator) !u8 {
        const se = b.se;
        var path: std.ArrayList([]const u8) = .empty;
        const args = try api.autoArgs(ev, b.a, se.c.flags.args.items);
        if (se.expr != null or se.file != null) {
            const root = if (se.expr) |e| try import_.evalString(ev, e) else try import_.evalFile(ev, se.file.?, .none);
            // Natively the root is auto-called, so a function like nixpkgs'
            // `default.nix` is a package set (docs/reference/commands.md).
            const r = if (se.native) try ev.autoCall(root, args) else root;
            const v = try api.installable.findAlongAttrPath(ev, r, se.what orelse "", args);
            try visit(b, ev, v, &path, true);
        } else {
            // `InstallableValue::getCursors`: a flake takes
            // `packages.<system>` and `legacyPackages.<system>`, or the
            // fragment under the same prefixes
            const attr = se.what orelse "";
            const hash = std.mem.indexOfScalar(u8, attr, '#');
            const loc = if (hash) |h| attr[0..h] else attr;
            const fragment = if (hash) |h| attr[h + 1 ..] else "";
            var d: @import("../diag.zig").Diag = .init(b.a);
            const fr = api.flake.flakeRef(b.a, ev.io, loc, b.cwd, &d) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return ev.fail(.unsupported, .none, "{s}", .{d.message()}),
            };
            const outputs = try api.flake.outputs(ev, &fr);
            const found = try api.installable.fromOutputs(ev, b.a, outputs, loc, .package_set, fragment, true);
            for (found) |f| {
                path.clearRetainingCapacity();
                var it = std.mem.splitScalar(u8, f.path, '.');
                while (it.next()) |x| try path.append(b.a, x);
                try visit(b, ev, f.value, &path, true);
            }
        }
        if (b.cache) |tc| try api.cache.writeEntry(tc, ev.config.session.?, ev, try encode(b.a, b.index.items), false);
        return 0;
    }

    /// search.cc:visit for one attribute path. `initial` marks a value the
    /// installable named. An evaluation error under `legacyPackages` is
    /// skipped, as in Nix; anywhere else it stops the search. The native
    /// command treats every path as `legacyPackages` does, so that a package
    /// set that is not a flake output is searched whole.
    fn visit(b: *Build, ev: *Evaluator, w: Value, path: *std.ArrayList([]const u8), initial: bool) Evaluator.Error!void {
        const skips = b.se.native or (path.items.len > 0 and std.mem.eql(u8, path.items[0], "legacyPackages"));
        visitInner(b, ev, w, path, initial) catch |e| switch (e) {
            error.EvalFailed => {
                const f = ev.failure orelse return e;
                if (!skips or !swallowed(f.kind)) return e;
                ev.clearFailure();
            },
            else => return e,
        };
    }

    fn visitInner(b: *Build, ev: *Evaluator, w: Value, path: *std.ArrayList([]const u8), initial: bool) Evaluator.Error!void {
        const v = try ev.force(w);
        const attrs: ?*Attrs = if (v.kind() == .attrs) v.as(Attrs) else null;
        if (attrs) |a| if (a.get(ev.s.type)) |t| {
            if (std.mem.eql(u8, try stringOf(b, ev, t.cell.get(), path.items, "type"), "derivation")) {
                try b.index.append(b.a, try entry(b, ev, a, path.items));
                return;
            }
        };
        if (!try recurses(b, ev, path.items, initial, attrs)) return;
        const a = attrs orelse return ev.fail(.type, .none, "'{s}' is not an attribute set", .{try show(b.a, path.items)});
        // parallel: the helpers force the children while the walk reads them
        if (ev.pool != null) ev.fanout(.attrs_whnf, .fromPtr(.ptr, a), 0, a.len, Evaluator.batch);
        const order = try print.lexicographic(ev, a);
        defer ev.gpa.free(order);
        for (order) |at| {
            try path.append(b.a, ev.interner.name(at.sym));
            defer _ = path.pop();
            try visit(b, ev, at.cell.get(), path, false);
        }
    }

    /// Whether the walk descends into an attribute set: everything the
    /// installable named, the two levels under `packages` and
    /// `legacyPackages`, and under `legacyPackages` (or anywhere, natively)
    /// a set with `recurseForDerivations = true`.
    fn recurses(b: *Build, ev: *Evaluator, path: []const []const u8, initial: bool, attrs: ?*Attrs) Evaluator.Error!bool {
        const head = if (path.len > 0) path[0] else "";
        const legacy = std.mem.eql(u8, head, "legacyPackages");
        const two = legacy or std.mem.eql(u8, head, "packages");
        if (path.len == 0 or initial or (two and path.len <= 2)) return true;
        if (b.se.native or legacy) if (attrs) |a| if (a.get(try ev.sym("recurseForDerivations"))) |r|
            return ev.forceBool(r.cell.get(), r.pos, "while evaluating recurseForDerivations");
        return false;
    }

    /// One derivation's index entry: `name` split into pname and version,
    /// and `meta.description` with its newlines turned into spaces.
    fn entry(b: *Build, ev: *Evaluator, a: *Attrs, path: []const []const u8) Evaluator.Error!Entry {
        const n = a.get(ev.s.name) orelse return ev.fail(.missing_attr, .none, "attribute '{s}.name' does not exist", .{try show(b.a, path)});
        const name = try stringOf(b, ev, n.cell.get(), path, "name");
        var desc: []u8 = &.{};
        if (a.get(try ev.sym("meta"))) |m| {
            const meta = try ev.force(m.cell.get());
            if (meta.kind() == .attrs) if (meta.as(Attrs).get(try ev.sym("description"))) |dd| {
                desc = try b.a.dupe(u8, try stringOf(b, ev, dd.cell.get(), path, "meta.description"));
            };
        }
        std.mem.replaceScalar(u8, desc, '\n', ' ');
        const pname, const version = strings.splitDrvName(name);
        return .{ .path = try std.mem.join(b.a, ".", path), .pname = try b.a.dupe(u8, pname), .version = try b.a.dupe(u8, version), .desc = desc };
    }

    /// eval-cache.cc:getString: a string or a path, anything else is an
    /// error.
    fn stringOf(b: *Build, ev: *Evaluator, w: Value, path: []const []const u8, what: []const u8) Evaluator.Error![]const u8 {
        const v = try ev.force(w);
        return switch (v.kind() orelse .int) {
            .string => v.as(value.String).bytes(),
            .path => v.as(value.Path).bytes(),
            else => ev.fail(.type, .none, "'{s}.{s}' is not a string but {s}", .{ try show(b.a, path), what, v.typeOf().name() }),
        };
    }
};

/// eval-error.hh: the errors `catch (EvalError &)` in search.cc swallows.
fn swallowed(k: Evaluator.ErrorKind) bool {
    return switch (k) {
        .eval, .type, .throw, .assert, .abort, .undefined_var, .infinite_recursion, .missing_attr => true,
        else => false,
    };
}

fn show(a: Allocator, path: []const []const u8) Allocator.Error![]const u8 {
    return std.mem.join(a, ".", path);
}

/// Every regex compiled; null with `code` the exit code of the report.
fn compileAll(s: *Session, a: Allocator, res: []const []const u8, code: *u8) ?[]regex.Prog {
    const out = a.alloc(regex.Prog, res.len) catch return null;
    for (res, out) |r, *p| p.* = regex.compileOpt(a, r, true) catch {
        const msg = std.fmt.allocPrint(a, "invalid regular expression '{s}'", .{r}) catch "invalid regular expression";
        code.* = help.argError(s, msg);
        return null;
    };
    return out;
}

const Spans = std.ArrayList([2]usize);

fn hit(a: Allocator, p: *const regex.Prog, s: []const u8) !bool {
    var m: regex.Matches = try .init(a, p, s);
    defer m.deinit();
    return (try m.next()) != null;
}

fn collect(a: Allocator, p: *const regex.Prog, s: []const u8, out: *Spans) !void {
    var m: regex.Matches = try .init(a, p, s);
    defer m.deinit();
    while (try m.next()) |x| try out.append(a, .{ x.start, x.end });
}

/// search.cc's match: every regex must match the attribute path, the
/// pname or the description; an exclude regex that matches any of the
/// three hides the package. The spans are what the text output highlights.
fn matched(a: Allocator, e: *const Entry, res: []const regex.Prog, exclude: []const regex.Prog) !?[2]Spans {
    for (exclude) |*p| if (try hit(a, p, e.path) or try hit(a, p, e.pname) or try hit(a, p, e.desc)) return null;
    var paths: Spans = .empty;
    var descs: Spans = .empty;
    for (res) |*p| {
        const before = .{ paths.items.len, descs.items.len };
        try collect(a, p, e.path, &paths);
        try collect(a, p, e.desc, &descs);
        if (paths.items.len == before[0] and descs.items.len == before[1] and !try hit(a, p, e.pname)) return null;
    }
    return .{ paths, descs };
}

/// hilite.cc:hiliteMatches: every match wrapped, continuous ones merged.
fn hilite(w: *Writer, s: []const u8, spans: [][2]usize, prefix: []const u8, postfix: []const u8) Writer.Error!void {
    if (spans.len == 0) return w.writeAll(s);
    std.mem.sort([2]usize, spans, {}, struct {
        fn lt(_: void, x: [2]usize, y: [2]usize) bool {
            return x[0] < y[0];
        }
    }.lt);
    var last: usize = 0;
    var i: usize = 0;
    while (i < spans.len) {
        const start = spans[i][0];
        var end = spans[i][1];
        try w.writeAll(s[last..start]);
        i += 1;
        while (i < spans.len and spans[i][0] <= end) : (i += 1) end = @max(end, spans[i][1]);
        try w.writeAll(prefix);
        try w.writeAll(s[start..end]);
        try w.writeAll(postfix);
        last = end;
    }
    try w.writeAll(s[last..]);
}

/// The whole output; the number of results.
fn showResults(w: *Writer, index: []const Entry, res: []const regex.Prog, exclude: []const regex.Prog, se: *const Search, s: *Session) !u64 {
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var json: std.ArrayList(*const Entry) = .empty;
    var results: u64 = 0;
    for (index) |*e| {
        const m = (try matched(a, e, res, exclude)) orelse continue;
        results += 1;
        if (se.json) {
            try json.append(a, e);
            continue;
        }
        if (results > 1) try w.writeByte('\n');
        try w.writeAll("* " ++ bold);
        try hilite(w, e.path, m[0].items, green, bold);
        try w.writeAll(normal);
        if (e.version.len > 0) try w.print(" ({s})", .{e.version});
        try w.writeByte('\n');
        if (e.desc.len > 0) {
            try w.writeAll("  ");
            try hilite(w, e.desc, m[1].items, green, normal);
            try w.writeByte('\n');
        }
    }
    if (se.json) try jsonOut(w, json.items, se.pretty orelse s.out.isTerminal());
    return results;
}

/// The object `--json` prints: one entry per package, keyed by attribute
/// path in byte order, the last of a path winning (a `BTreeMap`). A string
/// that is not UTF-8 is an error, as `nlohmann::json` makes it.
fn jsonOut(w: *Writer, entries: []*const Entry, pretty: bool) !void {
    std.mem.sort(*const Entry, entries, {}, struct {
        fn lt(_: void, x: *const Entry, y: *const Entry) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.lt);
    for (entries) |e| for ([_][]const u8{ e.path, e.desc, e.pname, e.version }) |t| {
        if (!std.unicode.utf8ValidateSlice(t)) return error.BadUtf8;
    };
    const nl = if (pretty) "\n" else "";
    const sep = if (pretty) ": " else ":";
    if (entries.len == 0) return w.writeAll("{}\n");
    try w.writeAll("{" ++ "");
    try w.writeAll(nl);
    var first = true;
    for (entries, 0..) |e, i| {
        // a later duplicate path replaces the earlier one
        if (i + 1 < entries.len and std.mem.eql(u8, entries[i + 1].path, e.path)) continue;
        if (!first) {
            try w.writeByte(',');
            try w.writeAll(nl);
        }
        first = false;
        if (pretty) try w.writeAll("  ");
        try text.writeJsonString(w, e.path);
        try w.writeAll(sep);
        try w.writeByte('{');
        try w.writeAll(nl);
        const fields = [_][2][]const u8{ .{ "description", e.desc }, .{ "pname", e.pname }, .{ "version", e.version } };
        for (fields, 0..) |f, k| {
            if (pretty) try w.writeAll("    ");
            try text.writeJsonString(w, f[0]);
            try w.writeAll(sep);
            try text.writeJsonString(w, f[1]);
            if (k + 1 < fields.len) try w.writeByte(',');
            try w.writeAll(nl);
        }
        if (pretty) try w.writeAll("  ");
        try w.writeByte('}');
    }
    try w.writeAll(nl);
    try w.writeAll("}\n");
}

/// The arguments the cache key is made of: the installable, the `--arg`s,
/// the search path and pure evaluation. The regexes are not in it, so a
/// second search over the same package set answers from the index.
fn keyArgs(se: *const Search) api.EvalArgs {
    var a: api.EvalArgs = .{};
    a.input = if (se.expr) |e| .{ .expr = e } else if (se.file) |f| .{ .file = f } else if (se.what) |w| .{ .flake = w } else null;
    if (se.expr != null or se.file != null) a.attr = se.what;
    // the native walk recurses and skips errors everywhere, so its index is
    // another index; `strict` is the key field that is free here
    a.strict = se.native;
    a.args = se.c.flags.args.items;
    a.includes = se.c.flags.includes.items;
    a.pure = se.c.flags.pure;
    a.timings = se.timings;
    a.no_tracing_cache = se.cache.no_tracing_cache;
    a.no_ir_cache = se.cache.no_ir_cache;
    a.cache_dir = se.cache.cache_dir;
    a.workers = se.cache.workers;
    return a;
}

/// The index as the cache entry keeps it: four length-prefixed fields per
/// package.
pub fn encode(a: Allocator, index: []const Entry) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (index) |e| for ([_][]const u8{ e.path, e.pname, e.version, e.desc }) |f| {
        var n: [4]u8 = undefined;
        std.mem.writeInt(u32, &n, @intCast(f.len), .little);
        try out.appendSlice(a, &n);
        try out.appendSlice(a, f);
    };
    return out.items;
}

/// `encode` read back; null for bytes it did not write.
pub fn decode(a: Allocator, b: []const u8) Allocator.Error!?[]Entry {
    var index: std.ArrayList(Entry) = .empty;
    var i: usize = 0;
    while (i < b.len) {
        var f: [4][]const u8 = undefined;
        for (&f) |*x| {
            if (i + 4 > b.len) return null;
            const n = std.mem.readInt(u32, b[i..][0..4], .little);
            if (i + 4 + n > b.len) return null;
            x.* = b[i + 4 .. i + 4 + n];
            i += 4 + n;
        }
        try index.append(a, .{ .path = f[0], .pname = f[1], .version = f[2], .desc = f[3] });
    }
    return index.items;
}

const testing = std.testing;

test "merged highlights" {
    var buf: [64]u8 = undefined;
    var w: Writer = .fixed(&buf);
    var s1 = [_][2]usize{ .{ 0, 4 }, .{ 4, 7 } };
    try hilite(&w, "goodbye", &s1, "<", ">");
    try testing.expectEqualStrings("<goodbye>", w.buffered());
    w = .fixed(&buf);
    var s2 = [_][2]usize{ .{ 2, 3 }, .{ 0, 1 } };
    try hilite(&w, "abcd", &s2, "<", ">");
    try testing.expectEqualStrings("<a>b<c>d", w.buffered());
}

test "index round trip" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const index = [_]Entry{
        .{ .path = "a.b", .pname = "b", .version = "", .desc = "x y" },
        .{ .path = "c", .pname = "c", .version = "1", .desc = "" },
    };
    const bytes = try encode(a, &index);
    const back = (try decode(a, bytes)).?;
    try testing.expectEqual(2, back.len);
    try testing.expectEqualStrings("c", back[1].path);
    try testing.expectEqualStrings("x y", back[0].desc);
    try testing.expectEqual(null, try decode(a, bytes[0..7]));
}

test "drv names" {
    const cases = [_][3][]const u8{
        .{ "hello-2.12", "hello", "2.12" },
        .{ "apache-httpd-2.0.48", "apache-httpd", "2.0.48" },
        .{ "gtk-doc", "gtk-doc", "" },
        .{ "hello", "hello", "" },
    };
    for (cases) |c| {
        const p, const v = strings.splitDrvName(c[0]);
        try testing.expectEqualStrings(c[1], p);
        try testing.expectEqualStrings(c[2], v);
    }
}
