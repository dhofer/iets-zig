//! Named lints for language corner cases, each `off`, `warn` or `error`.
//! The registry lives here, one line per lint; each family file holds the
//! trigger logic its hooks call (`lint/allow.zig` for `meta`). Levels
//! resolve from the built-in default, then `[lint]` in each `iets.toml`
//! (user, project), then `IETS_LINT`, then `--lint`; inside one source a
//! lint name beats `family:NAME`, which beats `all`. A site is reported only
//! inside the lint roots unless the scope is `all` or the site's locked
//! input has its own levels. See docs/reference/lints.md.

const std = @import("std");
const errors = @import("errors.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Why = @import("diag.zig").Diag;
const toml = @import("builtins/text/toml.zig");

pub const allow = @import("lint/allow.zig");
pub const site = @import("lint/site.zig");
pub const path = @import("lint/path.zig");
pub const legacy = @import("lint/legacy.zig");
pub const coerce = @import("lint/coerce.zig");
pub const purity = @import("lint/purity.zig");
pub const report = @import("lint/report.zig");

/// A compile-time diagnostic, carried from the compiler (or an IR cache
/// entry) to the evaluator that reports it.
pub const Diag = report.Diag;

pub const Level = enum(u8) {
    off,
    warn,
    @"error",

    /// `off`, `warn`, `error`, plus Nix's `ignore` and `fatal`.
    pub fn parse(s: []const u8) ?Level {
        if (eql(s, "off") or eql(s, "ignore")) return .off;
        if (eql(s, "warn")) return .warn;
        if (eql(s, "error") or eql(s, "fatal")) return .@"error";
        return null;
    }

    pub fn name(l: Level) []const u8 {
        return @tagName(l);
    }

    fn char(l: Level) u8 {
        return switch (l) {
            .off => 'o',
            .warn => 'w',
            .@"error" => 'e',
        };
    }
};

pub const Family = enum {
    path,
    coerce,
    legacy,
    purity,
    meta,

    pub fn parse(s: []const u8) ?Family {
        return std.meta.stringToEnum(Family, s);
    }

    pub fn name(f: Family) []const u8 {
        return @tagName(f);
    }
};

/// Where a lint fires. Parser and compiler lints run once per file and
/// travel with the IR cache entry; evaluator lints fire on demand.
pub const Hook = enum {
    parser,
    compiler,
    evaluator,

    pub fn name(h: Hook) []const u8 {
        return @tagName(h);
    }

    /// The lint runs while a file is compiled, so its level is part of the
    /// IR cache key and its warnings are stored in the entry.
    pub fn isCompileTime(h: Hook) bool {
        return h != .evaluator;
    }
};

pub const LintId = enum(u8) {
    absolute_path_literal,
    short_path_literal,
    url_literal,
    path_copy,
    dir_copy_flake,
    store_path_recopy,
    read_through_copy,
    drv_bool_null,
    drv_list,
    eq_type_mismatch,
    eq_function,
    or_non_attrs,
    impure_builtin,
    unhashed_fetch,
    ifd,
    ifd_local_output,
    fod,
    large_source_copy,
    git_in_source,
    dir_copy_unfiltered,
    impure_path_in_drv,
    absolute_path_in_drv,
    tree_meta_in_drv,
    rev_count,
    unknown_allow,

    pub inline fn def(id: LintId) *const Def {
        return &lints[@backingInt(id)];
    }

    pub inline fn name(id: LintId) []const u8 {
        return id.def().name;
    }

    pub fn fromByte(b: u8) ?LintId {
        return if (b < N) @fromBackingInt(b) else null;
    }
};

pub const Def = struct {
    id: LintId,
    name: []const u8,
    family: Family,
    hook: Hook,
    default: Level,
    doc: []const u8,
};

fn d(id: LintId, family: Family, hook: Hook, default: Level, doc: []const u8) Def {
    var n: [@tagName(id).len]u8 = @tagName(id)[0..].*;
    for (&n) |*c| if (c.* == '_') {
        c.* = '-';
    };
    const name = n;
    return .{ .id = id, .name = &name, .family = family, .hook = hook, .default = default, .doc = doc };
}

/// The registry, in `LintId` order: one line per lint.
pub const lints = [_]Def{
    d(.absolute_path_literal, .path, .compiler, .off, "a path literal that starts with `/` or `~/` (Nix: lint-absolute-path-literals)"),
    d(.short_path_literal, .path, .compiler, .off, "a relative path literal without a leading `./` (Nix: lint-short-path-literals)"),
    d(.url_literal, .legacy, .parser, .off, "an unquoted URL (Nix: lint-url-literals)"),
    d(.path_copy, .coerce, .evaluator, .off, "a path coerced to a string with a copy to the store (interpolation, `+`, derivation attrs); not under a flake tree"),
    d(.dir_copy_flake, .coerce, .evaluator, .off, "a directory of the flake tree (its tracked files) coerced to a string is copied to the store whole; narrow it with `lib.fileset` or `builtins.path` with a filter only when needed"),
    d(.store_path_recopy, .coerce, .evaluator, .off, "a path already under the store copied again, which doubles the hash in its name"),
    d(.read_through_copy, .coerce, .evaluator, .off, "a read (readFile, readDir, import, ...) of a store copy this evaluation made, when the original path would do"),
    d(.drv_bool_null, .coerce, .evaluator, .off, "a Boolean or null coerced into a derivation attribute (`\"1\"`, `\"\"`) by a `derivation` call in scope; Nix's own Boolean attributes excepted"),
    d(.drv_list, .coerce, .evaluator, .off, "a list space-joined into a derivation attribute by a `derivation` call in scope (`outputs` and `args` excepted)"),
    d(.eq_type_mismatch, .coerce, .evaluator, .off, "`==` or `!=` on values of different types (int and float excepted, and null on either side)"),
    d(.eq_function, .coerce, .evaluator, .off, "`==` or `!=` where a side is a function, which is never equal"),
    d(.or_non_attrs, .coerce, .evaluator, .off, "`x.a or d` where the subject of some element is not an attrset"),
    d(.impure_builtin, .purity, .evaluator, .off, "a `getEnv` call, or a reference to `currentTime`"),
    d(.unhashed_fetch, .purity, .evaluator, .off, "fetchurl, fetchTarball, fetchGit or fetchTree called without a hash, narHash or rev"),
    d(.ifd, .purity, .evaluator, .off, "import of a string that carries derivation context"),
    d(.ifd_local_output, .purity, .evaluator, .warn, "a read (import, readFile, readDir, ...) of a derivation output that this machine's store already holds, so a machine without it builds it or fails"),
    d(.fod, .purity, .evaluator, .off, "a fixed-output derivation; the message names the derivation and its hash mode"),
    d(.large_source_copy, .purity, .evaluator, .off, "a path copy whose NAR exceeds `max-bytes` (default 8 MiB)"),
    d(.git_in_source, .purity, .evaluator, .warn, "a path copy of a directory that contains a `.git` entry"),
    d(.dir_copy_unfiltered, .purity, .evaluator, .warn, "a directory coerced to a string is copied whole, untracked and ignored files included; use `builtins.path` with a filter"),
    d(.impure_path_in_drv, .purity, .evaluator, .@"error", "a derivation attribute holds the text of a path outside the store and outside any project root (`toString ./x`), so the .drv depends on the checkout location"),
    d(.absolute_path_in_drv, .purity, .evaluator, .@"error", "a derivation attribute holds the text of a path under a project root, an absolute path a flake evaluation would have copied"),
    d(.tree_meta_in_drv, .purity, .evaluator, .warn, "a derivation attribute holds metadata of the flake's source tree (`self.rev`, `self.lastModifiedDate`, ...), so each commit gives a new .drv and a rebuild; a locked input is silent without `[lint.inputs.<node>]`"),
    d(.rev_count, .purity, .evaluator, .warn, "the evaluation reads `revCount` of the flake's source tree, which is deprecated: the count is expensive, a shallow clone has none, and each commit changes it; use `lastModifiedDate` and `shortRev`; a locked input is silent without `[lint.inputs.<node>]`"),
    d(.unknown_allow, .meta, .parser, .warn, "a `# iets: allow` comment that names a lint the registry does not know, so a typo does not silence nothing"),
};

pub const N = lints.len;

comptime {
    for (lints, 0..) |l, i| std.debug.assert(@backingInt(l.id) == i);
    std.debug.assert(N == @typeInfo(LintId).@"enum".field_names.len);
}

/// Nix's names for the lints that predate the registry.
const aliases = [_]struct { []const u8, LintId }{
    .{ "lint-absolute-path-literals", .absolute_path_literal },
    .{ "lint-short-path-literals", .short_path_literal },
    .{ "lint-url-literals", .url_literal },
};

pub const default_max_bytes: u64 = 8 << 20;

/// Every lint at its default level, no roots: what an evaluator gets when
/// nothing resolved a configuration for it.
pub const default_config: Config = .{};

pub fn byName(name: []const u8) ?LintId {
    for (lints) |l| if (eql(l.name, name)) return l.id;
    for (aliases) |a| if (eql(a[0], name)) return a[1];
    return null;
}

/// Which files a lint site is reported in.
pub const Scope = enum {
    /// Sites inside a lint root only; a locked input's own levels
    /// (`[lint.inputs.<node>]`) open that input's tree.
    root,
    /// Every site, the store included.
    all,

    pub fn parse(s: []const u8) ?Scope {
        return std.meta.stringToEnum(Scope, s);
    }

    pub fn name(s: Scope) []const u8 {
        return @tagName(s);
    }
};

/// Where a lint site lies, for the scope rule.
pub const Where = union(enum) {
    /// Under a lint root, through the virtual copies.
    root,
    /// Inside the tree of the locked input at this index of `Config.inputs`.
    input: u32,
    /// The store, an input without its own levels, a pseudo-file.
    elsewhere,

    pub fn eq(a: Where, b: Where) bool {
        return switch (a) {
            .root => b == .root,
            .elsewhere => b == .elsewhere,
            .input => |i| b == .input and b.input == i,
        };
    }
};

/// How narrowly a selector names its lints: `all`, `family:NAME`, a name.
/// Inside one source the narrower selector wins, whatever the order.
pub const Specificity = enum(u8) { all, family, name };

/// One bit per lint.
pub const Mask = allow.Mask;

pub inline fn bit(id: LintId) Mask {
    return @as(Mask, 1) << @intCast(@backingInt(id));
}

pub const Selected = struct { spec: Specificity, mask: Mask };

/// `all`, `family:NAME`, a lint name, or a Nix alias, with its specificity.
pub fn select(selector: []const u8, dg: *Why) error{Unknown}!Selected {
    if (eql(selector, "all")) return .{ .spec = .all, .mask = all_mask };
    if (std.mem.startsWith(u8, selector, "family:")) {
        const f = selector["family:".len..];
        const fam = Family.parse(f) orelse return dg.fail(error.Unknown, "unknown lint family '{s}'", .{f});
        var m: Mask = 0;
        for (lints) |l| if (l.family == fam) {
            m |= bit(l.id);
        };
        return .{ .spec = .family, .mask = m };
    }
    const id = byName(selector) orelse return dg.fail(error.Unknown, "unknown lint '{s}'", .{selector});
    return .{ .spec = .name, .mask = bit(id) };
}

pub const all_mask: Mask = (@as(Mask, 1) << N) - 1;

/// The warnings resolving a configuration has for the user: a selector in
/// a file or `IETS_LINT` the registry does not know. One per key, in the
/// order they were made. A run hands them to its `ignored` warnings
/// (`give`), as `unknown-lint` warnings.
pub const Notes = struct {
    items: std.ArrayList(Note) = .empty,

    pub const Note = struct { key: []const u8, raw: []const u8 };

    /// Each note as an `unknown-lint` warning of the run, given now: a
    /// `warning:` line, or a record under `--log-format internal-json`.
    pub fn give(n: *const Notes, ig: *@import("ignored.zig").Ignored) Allocator.Error!void {
        for (n.items.items) |x| try ig.note("unknown-lint", x.key, x.raw);
        ig.flush();
    }

    fn note(n: *Notes, a: Allocator, key: []const u8, raw: []const u8) Allocator.Error!void {
        for (n.items.items) |x| if (eql(x.key, key)) return;
        try n.items.append(a, .{ .key = key, .raw = raw });
    }
};

/// The settings of one source (a `[lint]` table, `IETS_LINT`, the `--lint`
/// flags) before they reach the levels. A TOML table has no order, so
/// "later wins" cannot hold inside a source: a name beats `family:NAME`,
/// which beats `all`; among settings of one specificity the later one
/// wins. `apply` writes the result over the levels of the earlier sources.
pub const Layer = struct {
    levels: [N]?Slot = @splat(null),

    const Slot = struct { spec: Specificity, level: Level };

    /// `all`, `family:NAME`, a lint name, or a Nix alias.
    pub fn set(l: *Layer, selector: []const u8, level: Level, dg: *Why) error{Unknown}!void {
        const s = try select(selector, dg);
        for (&l.levels, 0..) |*slot, i| {
            if (s.mask & (@as(Mask, 1) << @intCast(i)) == 0) continue;
            if (slot.* == null or @backingInt(s.spec) >= @backingInt(slot.*.?.spec)) slot.* = .{ .spec = s.spec, .level = level };
        }
    }

    /// `set` for a file or `IETS_LINT`: a selector the registry does not
    /// know is one `unknown-lint` warning, and the run goes on. An error
    /// there stops every command in the repository, the one that installs
    /// the fix included.
    fn setFrom(l: *Layer, a: Allocator, selector: []const u8, level: Level, origin: []const u8, notes: *Notes) Allocator.Error!void {
        var dg: Why = .init(a);
        defer dg.deinit();
        l.set(selector, level, &dg) catch {
            const raw = try std.fmt.allocPrint(a, "{s}: iets does not know the lint '{s}' and ignores it; 'iets help lints' has the list (docs/reference/lints.md)", .{ origin, selector });
            try notes.note(a, try std.fmt.allocPrint(a, "{s} {s}", .{ origin, selector }), raw);
        };
    }

    /// `NAME=LEVEL`, as `--lint` takes it.
    pub fn setPair(l: *Layer, pair: []const u8, dg: *Why) error{ Unknown, BadLevel }!void {
        const p = try splitPair(pair, dg);
        try l.set(p.name, p.level, dg);
    }

    pub fn get(l: *const Layer, id: LintId) ?Level {
        const s = l.levels[@backingInt(id)] orelse return null;
        return s.level;
    }

    /// Writes every level this layer sets over `levels`.
    pub fn apply(l: *const Layer, levels: *[N]Level) void {
        for (levels, l.levels) |*slot, s| if (s) |x| {
            slot.* = x.level;
        };
    }
};

fn parseLevel(level: []const u8, name: []const u8, dg: *Why) error{BadLevel}!Level {
    return Level.parse(level) orelse dg.fail(error.BadLevel, "invalid lint level '{s}' for '{s}': use off, warn or error", .{ level, name });
}

const Pair = struct { name: []const u8, level: Level };

fn splitPair(pair: []const u8, dg: *Why) error{BadLevel}!Pair {
    const eq_at = std.mem.indexOfScalar(u8, pair, '=') orelse
        return dg.fail(error.BadLevel, "lint setting '{s}' is not NAME=LEVEL", .{pair});
    const name = pair[0..eq_at];
    return .{ .name = trim(name), .level = try parseLevel(trim(pair[eq_at + 1 ..]), name, dg) };
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn under(p: []const u8, dir: []const u8) bool {
    return std.mem.startsWith(u8, p, dir) and (p.len == dir.len or p[dir.len] == '/');
}

pub const Input = struct { name: []const u8, levels: [N]?Level };

/// The default level of every lint.
pub const defaults: [N]Level = blk: {
    var l: [N]Level = undefined;
    for (lints) |x| l[@backingInt(x.id)] = x.default;
    break :blk l;
};

/// The effective level of every lint plus the lint knobs and the scope.
/// Built once before evaluation; every worker reads it, nothing writes it.
pub const Config = struct {
    levels: [N]Level = defaults,
    /// `large-source-copy`: the NAR size a copy may reach.
    max_bytes: u64 = default_max_bytes,
    scope: Scope = .root,
    /// Canonical absolute directories: the entry directory, then `roots`
    /// of `iets.toml`, then `--lint-root`.
    roots: std.ArrayList([]const u8) = .empty,
    /// `[lint.inputs.<node>]`: the levels that hold inside that locked
    /// input's tree, by lock node name; null leaves the scope rule.
    inputs: std.ArrayList(Input) = .empty,

    /// Every lint off: classic mode prints what Nix prints, and a library
    /// evaluator that asked for nothing reports nothing.
    pub const off: Config = .{ .levels = @splat(.off) };

    pub inline fn level(c: *const Config, id: LintId) Level {
        return c.levels[@backingInt(id)];
    }

    pub inline fn on(c: *const Config, id: LintId) bool {
        return c.levels[@backingInt(id)] != .off;
    }

    /// The lints not `off`, one bit each.
    pub fn mask(c: *const Config) Mask {
        var m: Mask = 0;
        for (lints) |l| if (c.on(l.id)) {
            m |= bit(l.id);
        };
        return m;
    }

    /// One selector as a source of its own.
    pub fn set(c: *Config, selector: []const u8, lv: Level, dg: *Why) error{Unknown}!void {
        var l: Layer = .{};
        try l.set(selector, lv, dg);
        l.apply(&c.levels);
    }

    /// `NAME=LEVEL` as a source of its own, as `--lint` takes it.
    pub fn setPair(c: *Config, pair: []const u8, dg: *Why) error{ Unknown, BadLevel }!void {
        var l: Layer = .{};
        try l.setPair(pair, dg);
        l.apply(&c.levels);
    }

    /// Adds a lint root; `dir` is made canonical.
    pub fn addRoot(c: *Config, a: Allocator, dir: []const u8) Allocator.Error!void {
        const canon = try canonPath(a, dir);
        for (c.roots.items) |r| if (eql(r, canon)) return;
        try c.roots.append(a, canon);
    }

    pub fn inputIndex(c: *const Config, name: []const u8) ?u32 {
        for (c.inputs.items, 0..) |x, i| if (eql(x.name, name)) return @intCast(i);
        return null;
    }

    /// Whether any site can be silenced by where it lies: false with
    /// `scope = "all"` and no input levels, the fast path.
    pub inline fn scoped(c: *const Config) bool {
        return c.scope == .root or c.inputs.items.len > 0;
    }

    /// The level of `id` at a site that lies at `w`.
    pub fn siteLevel(c: *const Config, id: LintId, w: Where) Level {
        const global = c.level(id);
        const outside: Level = switch (c.scope) {
            .all => global,
            .root => .off,
        };
        return switch (w) {
            .root => global,
            .input => |i| c.inputs.items[i].levels[@backingInt(id)] orelse outside,
            .elsewhere => outside,
        };
    }

    /// Whether a lint root contains `p` (a local, canonical path).
    pub fn inRoot(c: *const Config, p: []const u8) bool {
        for (c.roots.items) |r| if (under(p, r)) return true;
        return false;
    }

    /// The configuration a file at `w` is compiled under: every level
    /// replaced by its `siteLevel`. Shares the roots and inputs of `c`.
    pub fn forWhere(c: *const Config, w: Where) Config {
        var r = c.*;
        if (w != .root and c.scoped()) {
            for (lints) |l| r.levels[@backingInt(l.id)] = c.siteLevel(l.id, w);
        }
        return r;
    }

    /// `IETS_LINT="name=level,name=level"`: one source.
    pub fn applyEnv(c: *Config, a: Allocator, s: []const u8, notes: *Notes, dg: *Why) (Allocator.Error || error{BadLevel})!void {
        var l: Layer = .{};
        var it = std.mem.splitScalar(u8, s, ',');
        while (it.next()) |raw| {
            const pair = trim(raw);
            if (pair.len == 0) continue;
            const p = try splitPair(pair, dg);
            try l.setFrom(a, p.name, p.level, "IETS_LINT", notes);
        }
        l.apply(&c.levels);
    }

    /// The `[lint]` table of an `iets.toml`: `name = "level"`, or
    /// `name = { level = "warn", max-bytes = 1000 }` for a lint with knobs,
    /// plus `scope`, `roots` (relative to the file) and `inputs.<node>`.
    pub fn applyToml(c: *Config, a: Allocator, text: []const u8, origin: []const u8, notes: *Notes, dg: *Why) (Allocator.Error || error{BadConfig})!void {
        var err: toml.ParseError = .{};
        const doc = toml.parseTable(a, text, &err) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Syntax => {
                var r: std.Io.Writer.Allocating = .init(a);
                toml.renderError(&r.writer, text, err) catch return error.OutOfMemory;
                return dg.fail(error.BadConfig, "{s}: {s}", .{ origin, r.written() });
            },
        };
        const lint_node = doc.map.get("lint") orelse return;
        if (lint_node != .table) return dg.fail(error.BadConfig, "{s}: 'lint' is not a table", .{origin});
        var l: Layer = .{};
        // Rust iets reads a TOML table as a sorted map: the keys come in
        // byte order, which decides the order of the warnings and which of
        // two equally specific settings wins, so they must here too.
        const t = lint_node.table;
        const keys = try sortedKeys(a, t);
        for (keys) |name| {
            const v = t.map.get(name).?;
            if (eql(name, "scope")) {
                if (v != .string) return dg.fail(error.BadConfig, "{s}: 'scope' must be \"root\" or \"all\"", .{origin});
                c.scope = Scope.parse(v.string) orelse
                    return dg.fail(error.BadConfig, "{s}: invalid lint scope '{s}': use root or all", .{ origin, v.string });
            } else if (eql(name, "roots")) {
                if (v != .array) return dg.fail(error.BadConfig, "{s}: 'roots' must be a list of strings", .{origin});
                const base = std.fs.path.dirname(origin) orelse "/";
                for (v.array.items.items) |x| {
                    if (x != .string) return dg.fail(error.BadConfig, "{s}: 'roots' must be a list of strings", .{origin});
                    const joined = if (std.fs.path.isAbsolute(x.string)) x.string else try std.fs.path.join(a, &.{ base, x.string });
                    try c.addRoot(a, joined);
                }
            } else if (eql(name, "inputs")) {
                if (v != .table) return dg.fail(error.BadConfig, "{s}: 'inputs' must be a table", .{origin});
                c.applyInputs(a, v.table, origin, notes, dg) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.BadConfig => return dg.fail(error.BadConfig, "{s}: {s}", .{ origin, try a.dupe(u8, dg.message()) }),
                };
            } else switch (v) {
                .string => |s| {
                    const lv = parseLevel(s, name, dg) catch return atOrigin(dg, origin);
                    try l.setFrom(a, name, lv, origin, notes);
                },
                .table => |sub| if (byName(name) == null) {
                    try l.setFrom(a, name, .off, origin, notes);
                } else for (try sortedKeys(a, sub)) |k| {
                    const kv = sub.map.get(k).?;
                    if (eql(k, "level") and kv == .string) {
                        const lv = parseLevel(kv.string, name, dg) catch return atOrigin(dg, origin);
                        try l.setFrom(a, name, lv, origin, notes);
                    } else if (eql(name, "large-source-copy") and eql(k, "max-bytes") and kv == .integer) {
                        c.max_bytes = @intCast(@max(kv.integer, 0));
                    } else return dg.fail(error.BadConfig, "{s}: unknown key '{s}' for lint '{s}'", .{ origin, k, name });
                },
                else => return dg.fail(error.BadConfig, "{s}: lint '{s}' must be a level string or a table", .{ origin, name }),
            }
        }
        l.apply(&c.levels);
    }

    fn atOrigin(dg: *Why, origin: []const u8) error{ BadConfig, OutOfMemory } {
        const m = dg.gpa.dupe(u8, dg.message()) catch return error.OutOfMemory;
        defer dg.gpa.free(m);
        return dg.fail(error.BadConfig, "{s}: {s}", .{ origin, m });
    }

    fn applyInputs(c: *Config, a: Allocator, t: *const toml.Table, origin: []const u8, notes: *Notes, dg: *Why) (Allocator.Error || error{BadConfig})!void {
        for (try sortedKeys(a, t)) |input| {
            const v = t.map.get(input).?;
            if (v != .table) return dg.fail(error.BadConfig, "'inputs.{s}' is not a table", .{input});
            var l: Layer = .{};
            for (try sortedKeys(a, v.table)) |selector| {
                const lv = v.table.map.get(selector).?;
                if (lv != .string) return dg.fail(error.BadConfig, "lint '{s}' of input '{s}' must be a level string", .{ selector, input });
                const parsed = parseLevel(lv.string, selector, dg) catch return error.BadConfig;
                try l.setFrom(a, selector, parsed, origin, notes);
            }
            var arr: [N]?Level = undefined;
            for (lints) |x| arr[@backingInt(x.id)] = l.get(x.id);
            if (c.inputIndex(input)) |i| {
                c.inputs.items[i].levels = arr;
            } else try c.inputs.append(a, .{ .name = try a.dupe(u8, input), .levels = arr });
        }
    }

    /// One byte per lint plus the knobs and the scope: the cache key field.
    pub fn key(c: *const Config, a: Allocator) Allocator.Error![]u8 {
        var s: std.Io.Writer.Allocating = .init(a);
        const w = &s.writer;
        (blk: {
            for (c.levels) |l| w.writeByte(l.char()) catch |e| break :blk e;
            w.print(":{d}:{s}", .{ c.max_bytes, c.scope.name() }) catch |e| break :blk e;
            for (c.roots.items) |r| w.print(":{s}", .{r}) catch |e| break :blk e;
            for (c.inputs.items) |x| {
                w.print(":{s}=", .{x.name}) catch |e| break :blk e;
                for (x.levels) |l| w.writeByte(if (l) |v| v.char() else '-') catch |e| break :blk e;
            }
        }) catch return error.OutOfMemory;
        return s.toOwnedSlice();
    }

    /// The compile-time lints only: the IR cache key field. Empty when they
    /// are all off, so an unlinted file keys as it did before the registry.
    pub fn compileKey(c: *const Config, buf: *[N]u8) []const u8 {
        var any = false;
        for (lints) |l| if (l.hook.isCompileTime() and c.on(l.id)) {
            any = true;
        };
        if (!any) return "";
        for (lints, buf) |l, *b| b.* = if (l.hook.isCompileTime()) c.level(l.id).char() else '-';
        return buf;
    }

    /// Whether any compile-time lint is on: a file then compiles in order,
    /// since a lint is an effect.
    pub fn anyCompileTime(c: *const Config) bool {
        inline for (lints) |l| if (comptime l.hook.isCompileTime()) {
            if (c.on(l.id)) return true;
        };
        return false;
    }

    /// Default, then the user's `iets.toml`, then the project `iets.toml`
    /// found by walking up from `start`, then `IETS_LINT`, then `flags` as
    /// one source. `start` is the first lint root; `roots` (`--lint-root`)
    /// follow and `scope` (`--lint-scope`) wins over the file's.
    pub fn resolve(a: Allocator, io: Io, env: Env, start: ?[]const u8, flags: []const Flag, roots: []const []const u8, scope: ?Scope, notes: *Notes, dg: *Why) (Allocator.Error || error{BadConfig})!Config {
        var c: Config = .{};
        if (start) |dir| try c.addRoot(a, dir);
        const settings = try settingsFile(a, env);
        const settings_text = readFile(a, io, settings) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FileNotFound, error.NotDir, error.IsDir => null,
            else => return dg.fail(error.BadConfig, "{s}: {s}", .{ settings, errors.ioText(e) }),
        };
        if (settings_text) |text| c.applyToml(a, text, settings, notes, dg) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.BadConfig,
        };
        if (start) |dir| if (try findConfigFile(a, io, dir)) |file| {
            // a walk that starts below the settings directory ends on the file read above
            const same = blk: {
                if (settings_text == null) break :blk false;
                const x = Io.Dir.cwd().realPathFileAlloc(io, file, a) catch break :blk false;
                const y = Io.Dir.cwd().realPathFileAlloc(io, settings, a) catch break :blk false;
                break :blk eql(x, y);
            };
            if (!same) {
                const text = readFile(a, io, file) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return dg.fail(error.BadConfig, "{s}: {s}", .{ file, errors.ioText(e) }),
                } orelse "";
                try checkProject(a, text, file, settings, dg);
                c.applyToml(a, text, file, notes, dg) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.BadConfig,
                };
            }
        };
        if (env.iets_lint) |levels| c.applyEnv(a, levels, notes, dg) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadLevel => {
                const m = try a.dupe(u8, dg.message());
                return dg.fail(error.BadConfig, "IETS_LINT: {s}", .{m});
            },
        };
        var l: Layer = .{};
        for (flags) |f| l.set(f.selector, f.level, dg) catch return error.BadConfig;
        l.apply(&c.levels);
        for (roots) |r| try c.addRoot(a, r);
        if (scope) |s| c.scope = s;
        return c;
    }

    /// `iets lint list`: every lint with its effective level.
    pub fn list(c: *const Config, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (lints) |l| {
            const lv = c.level(l.id);
            var buf: [32]u8 = undefined;
            const dflt = if (lv == l.default) "" else std.fmt.bufPrint(&buf, " (default {s})", .{l.default.name()}) catch unreachable;
            try w.print("{s:<24} {s:<5}{s:<16} {s:<8} {s:<9} {s}\n", .{ l.name, lv.name(), dflt, l.family.name(), l.hook.name(), l.doc });
        }
        try w.print("scope: {s}", .{c.scope.name()});
        if (c.scope == .root) {
            try w.writeAll(" (roots: ");
            for (c.roots.items, 0..) |r, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll(r);
            }
            try w.writeByte(')');
        }
        try w.writeByte('\n');
        for (c.inputs.items) |x| {
            try w.print("input {s}: ", .{x.name});
            var first = true;
            for (lints) |l| if (x.levels[@backingInt(l.id)]) |lv| {
                if (!first) try w.writeAll(", ");
                first = false;
                try w.print("{s}={s}", .{ l.name, lv.name() });
            };
            try w.writeByte('\n');
        }
    }
};

/// A `--lint` flag, checked: a selector and its level.
pub const Flag = struct { selector: []const u8, level: Level };

/// `--lint SELECTOR=LEVEL`: the selector is checked against the registry
/// now, so a typo is a usage error before anything runs.
pub fn parseFlag(v: []const u8, dg: *Why) error{ Unknown, BadLevel }!Flag {
    var probe: Layer = .{};
    try probe.setPair(v, dg);
    const p = splitPair(v, dg) catch unreachable;
    return .{ .selector = p.name, .level = p.level };
}

/// What the configuration reads from the environment.
pub const Env = struct {
    home: ?[]const u8 = null,
    xdg_config_home: ?[]const u8 = null,
    iets_lint: ?[]const u8 = null,

    pub fn fromMap(m: *const std.process.Environ.Map) Env {
        return .{ .home = nonEmpty(m.get("HOME")), .xdg_config_home = nonEmpty(m.get("XDG_CONFIG_HOME")), .iets_lint = m.get("IETS_LINT") };
    }

    fn nonEmpty(s: ?[]const u8) ?[]const u8 {
        const v = s orelse return null;
        return if (v.len == 0) null else v;
    }
};

/// `$XDG_CONFIG_HOME/iets/iets.toml`, else `$HOME/.config/iets/iets.toml`:
/// `settings.confFile` over the lint configuration's own `Env`, which a
/// test builds without a process environment.
pub fn settingsFile(a: Allocator, env: Env) Allocator.Error![]const u8 {
    if (env.xdg_config_home) |x| return std.fs.path.join(a, &.{ x, "iets/iets.toml" });
    return std.fs.path.join(a, &.{ env.home orelse "/", ".config/iets/iets.toml" });
}

/// The settings a project file may not set: `settings::KEYS`.
const settings_keys = @import("settings.zig").keys;

/// Refuses every key of a project's `iets.toml` but `lint`. The file comes
/// with whatever repository was cloned, so it may not decide what runs
/// (`nix-bin-dir`), where sources go (`builder`) or what gets rewritten
/// (`fix-hashes`).
pub fn checkProject(a: Allocator, text: []const u8, origin: []const u8, settings: []const u8, dg: *Why) error{ BadConfig, OutOfMemory }!void {
    // a file that does not parse is `applyToml`'s to report
    var err: toml.ParseError = .{};
    const doc = toml.parseTable(a, text, &err) catch return;
    for (try sortedKeys(a, doc)) |k| {
        if (eql(k, "lint")) continue;
        var known = false;
        for (settings_keys) |s| known = known or eql(s, k);
        if (known) return dg.fail(error.BadConfig, "{s}: '{s}' may not be set in a project file: a repository controls this file; set it in {s}", .{ origin, k, settings });
        return dg.fail(error.BadConfig, "{s}: '{s}' may not be set in a project file: it holds only [lint]", .{ origin, k });
    }
}

/// The nearest project `iets.toml` at or above `start`, stopping at the
/// project root. The walk must not leave the project: a world-writable
/// `/tmp/iets.toml` would otherwise set a lint level for every evaluation
/// below it, and the file is untrusted input (`checkProject`).
pub fn findConfigFile(a: Allocator, io: Io, start: []const u8) Allocator.Error!?[]const u8 {
    const root = (findProjectRoot(io, a, start) catch return null) orelse return null;
    var dir = start;
    while (true) {
        const f = try std.fs.path.join(a, &.{ dir, "iets.toml" });
        if (isFile(io, f)) return f;
        if (eql(dir, root) or dir.len <= 1) return null;
        dir = std.fs.path.dirname(dir) orelse return null;
    }
}

fn findProjectRoot(io: Io, a: Allocator, start: []const u8) !?[]const u8 {
    return @import("builtins/store_hooks.zig").findProjectRoot(io, a, start);
}

fn isFile(io: Io, p: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, p, .{}) catch return false;
    return st.kind == .file;
}

fn readFile(a: Allocator, io: Io, p: []const u8) !?[]u8 {
    if (!isFile(io, p)) return null;
    return try Io.Dir.cwd().readFileAlloc(io, p, a, .unlimited);
}

fn sortedKeys(a: Allocator, t: *const toml.Table) Allocator.Error![]const []const u8 {
    const keys = try a.dupe([]const u8, t.map.keys());
    std.mem.sort([]const u8, keys, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    return keys;
}

fn canonPath(a: Allocator, p: []const u8) Allocator.Error![]const u8 {
    return @import("eval/Evaluator.zig").canonPath(a, p) catch return error.OutOfMemory;
}

inline fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// The message of a lint at `error`: `[NAME] MSG`.
pub fn errorMessage(id: LintId, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("[{s}] ", .{id.name()});
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("lint/tests.zig");
}

const testing = std.testing;

test "names are unique kebab-case" {
    for (lints, 0..) |l, i| {
        for (lints[0..i]) |o| try testing.expect(!eql(o.name, l.name));
        for (l.name) |c| try testing.expect(std.ascii.isLower(c) or c == '-' or std.ascii.isDigit(c));
        try testing.expectEqual(l.id, byName(l.name).?);
        try testing.expectEqual(l.id, LintId.fromByte(@backingInt(l.id)).?);
    }
    try testing.expectEqualStrings("absolute-path-literal", LintId.absolute_path_literal.name());
}

test "selectors and order" {
    var dg: Why = .init(testing.allocator);
    defer dg.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c: Config = .{};
    try c.set("all", .warn, &dg);
    for (c.levels) |l| try testing.expectEqual(Level.warn, l);
    try c.set("family:path", .@"error", &dg);
    try testing.expectEqual(Level.@"error", c.level(.absolute_path_literal));
    try testing.expectEqual(Level.warn, c.level(.path_copy));
    try c.setPair("absolute-path-literal=off", &dg);
    try testing.expectEqual(Level.off, c.level(.absolute_path_literal));
    try c.setPair("lint-url-literals=fatal", &dg);
    try testing.expectEqual(Level.@"error", c.level(.url_literal));
    try testing.expectError(error.Unknown, c.set("nope", .warn, &dg));
    try testing.expectError(error.Unknown, c.set("family:nope", .warn, &dg));
    try testing.expectError(error.BadLevel, c.setPair("absolute-path-literal=loud", &dg));
    var notes: Notes = .{};
    try c.applyEnv(a, "absolute-path-literal=warn, ifd=error", &notes, &dg);
    try testing.expectEqual(Level.warn, c.level(.absolute_path_literal));
    try testing.expectEqual(Level.@"error", c.level(.ifd));
}

test "specificity inside a source and order between sources" {
    var dg: Why = .init(testing.allocator);
    defer dg.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var notes: Notes = .{};
    var c: Config = .{};
    try c.applyToml(a, "[lint]\nabsolute-path-literal = \"warn\"\n\"family:path\" = \"error\"\nall = \"off\"\ndir-copy-flake = \"warn\"\n\"family:coerce\" = \"error\"\n", "t", &notes, &dg);
    try testing.expectEqual(Level.warn, c.level(.absolute_path_literal));
    try testing.expectEqual(Level.@"error", c.level(.short_path_literal));
    try testing.expectEqual(Level.warn, c.level(.dir_copy_flake));
    try testing.expectEqual(Level.@"error", c.level(.path_copy));
    try testing.expectEqual(Level.off, c.level(.ifd));
    c = .{};
    try c.applyToml(a, "[lint]\n\"family:path\" = \"error\"\nlint-short-path-literals = \"warn\"\n", "t", &notes, &dg);
    try testing.expectEqual(Level.warn, c.level(.short_path_literal));
    try testing.expectEqual(Level.@"error", c.level(.absolute_path_literal));
    c = .{};
    try c.applyToml(a, "[lint.inputs.dep]\nfod = \"warn\"\nall = \"error\"\n", "t", &notes, &dg);
    const i = c.inputIndex("dep").?;
    try testing.expectEqual(Level.warn, c.siteLevel(.fod, .{ .input = i }));
    try testing.expectEqual(Level.@"error", c.siteLevel(.ifd, .{ .input = i }));
    c = .{};
    try c.applyToml(a, "[lint]\nabsolute-path-literal = \"warn\"\n", "t", &notes, &dg);
    try c.applyEnv(a, "family:path=error", &notes, &dg);
    try testing.expectEqual(Level.@"error", c.level(.absolute_path_literal));
    try c.set("all", .off, &dg);
    try testing.expectEqual(Level.off, c.level(.absolute_path_literal));
    const flags = struct {
        fn f(s: []const []const u8) !Config {
            var dg2: Why = .init(testing.allocator);
            defer dg2.deinit();
            var l: Layer = .{};
            for (s) |p| try l.setPair(p, &dg2);
            var r: Config = .{};
            l.apply(&r.levels);
            return r;
        }
    }.f;
    try testing.expectEqual(Level.off, (try flags(&.{ "absolute-path-literal=off", "all=error" })).level(.absolute_path_literal));
    try testing.expectEqual(Level.off, (try flags(&.{ "all=error", "absolute-path-literal=off" })).level(.absolute_path_literal));
    try testing.expectEqual(Level.@"error", (try flags(&.{ "all=error", "absolute-path-literal=off" })).level(.ifd));
    try testing.expectEqual(Level.off, (try flags(&.{ "absolute-path-literal=off", "family:path=error" })).level(.absolute_path_literal));
    try testing.expectEqual(Level.warn, (try flags(&.{ "absolute-path-literal=off", "absolute-path-literal=warn" })).level(.absolute_path_literal));
    try testing.expectEqual(Level.warn, (try flags(&.{ "all=off", "all=warn" })).level(.absolute_path_literal));
    c = .{};
    try c.applyEnv(a, "family:path=error, absolute-path-literal=off", &notes, &dg);
    try testing.expectEqual(Level.off, c.level(.absolute_path_literal));
    try testing.expectEqual(Level.@"error", c.level(.short_path_literal));
}

test "toml table" {
    var dg: Why = .init(testing.allocator);
    defer dg.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var notes: Notes = .{};
    var c: Config = .{};
    try c.applyToml(a, "[other]\nx = 1\n[lint]\nabsolute-path-literal = \"warn\"\nlarge-source-copy = { level = \"error\", max-bytes = 64 }\n", "t", &notes, &dg);
    try testing.expectEqual(Level.warn, c.level(.absolute_path_literal));
    try testing.expectEqual(Level.@"error", c.level(.large_source_copy));
    try testing.expectEqual(64, c.max_bytes);
    try testing.expectError(error.BadConfig, c.applyToml(a, "[lint]\nabsolute-path-literal = 3\n", "t", &notes, &dg));
    try testing.expectError(error.BadConfig, c.applyToml(a, "[lint]\nabsolute-path-literal = { max-bytes = 3 }\n", "t", &notes, &dg));
}

test "keys" {
    var dg: Why = .init(testing.allocator);
    defer dg.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [N]u8 = undefined;
    var c: Config = .{};
    try c.set("all", .off, &dg);
    try testing.expectEqualStrings("", c.compileKey(&buf));
    try c.set("path-copy", .warn, &dg);
    try testing.expectEqualStrings("", c.compileKey(&buf));
    const off_c = c;
    try c.set("absolute-path-literal", .warn, &dg);
    try testing.expect(std.mem.indexOfScalar(u8, c.compileKey(&buf), 'w') != null);
    try testing.expect(!eql(try c.key(a), try off_c.key(a)));
    var all = c;
    all.scope = .all;
    try testing.expect(!eql(try all.key(a), try c.key(a)));
    var rooted = c;
    rooted.roots = .empty;
    try rooted.addRoot(a, "/r");
    try testing.expect(!eql(try rooted.key(a), try c.key(a)));
}

test "scope and inputs" {
    var dg: Why = .init(testing.allocator);
    defer dg.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var notes: Notes = .{};
    var buf: [N]u8 = undefined;
    var c: Config = .{};
    try c.applyToml(a, "[lint]\nabsolute-path-literal = \"warn\"\nroots = [\"lib\", \"/abs/../x\"]\n[lint.inputs.nixpkgs]\nfod = \"warn\"\n\"family:path\" = \"off\"\n", "/repo/iets.toml", &notes, &dg);
    try testing.expectEqual(Scope.root, c.scope);
    try testing.expectEqual(2, c.roots.items.len);
    try testing.expectEqualStrings("/repo/lib", c.roots.items[0]);
    try testing.expectEqualStrings("/x", c.roots.items[1]);
    try testing.expect(c.inRoot("/repo/lib/a.nix"));
    try testing.expect(!c.inRoot("/repo/library/a.nix"));
    const i: Where = .{ .input = c.inputIndex("nixpkgs").? };
    try testing.expectEqual(Level.warn, c.siteLevel(.absolute_path_literal, .root));
    try testing.expectEqual(Level.off, c.siteLevel(.absolute_path_literal, .elsewhere));
    try testing.expectEqual(Level.off, c.siteLevel(.absolute_path_literal, i));
    try testing.expectEqual(Level.warn, c.siteLevel(.fod, i));
    try testing.expectEqual(Level.warn, c.forWhere(i).level(.fod));
    try testing.expectEqualStrings("", c.forWhere(.elsewhere).compileKey(&buf));
    c.scope = .all;
    try testing.expectEqual(Level.warn, c.siteLevel(.absolute_path_literal, .elsewhere));
    try testing.expectEqual(Level.off, c.siteLevel(.absolute_path_literal, i));
    try testing.expectError(error.BadConfig, c.applyToml(a, "[lint]\nscope = \"some\"\n", "t", &notes, &dg));
    try testing.expectError(error.BadConfig, c.applyToml(a, "[lint]\nroots = \"lib\"\n", "t", &notes, &dg));
    var e: Config = .{};
    try e.applyToml(a, "[lint]\nscope = \"all\"\n", "t", &notes, &dg);
    try testing.expectEqual(Scope.all, e.scope);
    try testing.expect(!e.scoped());
}

test "an unknown name is a warning in a file and an error in a flag" {
    var dg: Why = .init(testing.allocator);
    defer dg.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var notes: Notes = .{};
    var c: Config = .{};
    try c.applyToml(a, "[lint]\nnope = \"error\"\n\"family:nope\" = \"warn\"\ngone = { level = \"warn\" }\nfod = \"warn\"\n[lint.inputs.x]\nnope = \"warn\"\n", "/r/iets.toml", &notes, &dg);
    try c.applyEnv(a, "nope=warn, ifd=error", &notes, &dg);
    try testing.expectEqual(Level.warn, c.level(.fod));
    try testing.expectEqual(Level.@"error", c.level(.ifd));
    const want = [_][]const u8{ "/r/iets.toml family:nope", "/r/iets.toml gone", "/r/iets.toml nope", "IETS_LINT nope" };
    try testing.expectEqual(want.len, notes.items.items.len);
    for (want, notes.items.items) |w, n| try testing.expectEqualStrings(w, n.key);
    try testing.expectError(error.BadLevel, c.applyEnv(a, "nope=loud", &notes, &dg));
    try testing.expectError(error.Unknown, c.setPair("nope=warn", &dg));
}

test "the project file walk stops at the project root" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(io, "repo/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "iets.toml", .data = "[lint]\n" });
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    const deep = try std.fs.path.join(a, &.{ base, "repo/sub" });
    // the temporary directory may lie inside a project of its own, whose
    // root then ends the walk first; only a walk that reaches the file is checked
    const found = try findConfigFile(a, io, deep);
    if (found) |f| try testing.expectEqualStrings(try std.fs.path.join(a, &.{ base, "iets.toml" }), f);
    try tmp.dir.createDirPath(io, "repo/.git");
    try testing.expect(try findConfigFile(a, io, deep) == null);
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/iets.toml", .data = "[lint]\n" });
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ base, "repo/iets.toml" }), (try findConfigFile(a, io, deep)).?);
}
