//! Reporting a lint site from the evaluator: the scope rule, `# iets: allow`,
//! one warning per site, and the error at level `error`.
//!
//! Any fiber reports: the site set keeps a warning to one line, and bailing
//! like `trace` cost 15 % of the wall. A helper's warning is
//! deferred (`eval/effects.zig`): it comes out when the demand path takes
//! the value whose evaluation reached the site, in sequential order.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lint = @import("../lint.zig");
const LintId = lint.LintId;
const Level = lint.Level;
const Where = lint.Where;
const Evaluator = @import("../eval/Evaluator.zig");
const Error = Evaluator.Error;
const Pos = @import("../syntax/pos.zig").Pos;
const Files = @import("../eval/Files.zig");
const effects = @import("../eval/effects.zig");
const store_hooks = @import("../builtins/store_hooks.zig");

/// A compile-time diagnostic, carried from the compiler (or an IR cache
/// entry) to the evaluator that reports it. `msg` is owned by whoever holds
/// the list.
pub const Diag = struct { id: LintId, pos: Pos, msg: []const u8 };

/// Warnings wait in `pending` until it holds this much, then go to stderr
/// in one write: 13k lines on nixos-server cost 7 % of the wall at 4
/// workers as one syscall each.
const flush_at = 16 << 10;

/// The warnings a run emitted, shared by every fiber.
pub const Emitted = struct {
    lock: std.Io.Mutex = .init,
    /// Sites reported or silenced: `id << 32 | pos`.
    seen: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// The text of every warning, in order; with `sites`, what a cache
    /// entry keeps as records.
    records: std.ArrayList([]u8) = .empty,
    /// The span and the edit of each record's site, when it was looked
    /// for: under internal-json, and for the tracing cache's entry, whose
    /// replay shows them. Its strings are the general allocator's.
    sites: std.ArrayList(?@import("../log.zig").Site) = .empty,
    /// The trees that have their finding of `rev-count`.
    counted: std.ArrayList([]u8) = .empty,
    pending: std.ArrayList(u8) = .empty,
    /// Where `flush` writes; the command line sets it.
    out: ?*std.Io.Writer = null,

    pub fn deinit(e: *Emitted, gpa: Allocator) void {
        e.seen.deinit(gpa);
        for (e.records.items) |r| gpa.free(r);
        e.records.deinit(gpa);
        for (e.sites.items) |x| if (x) |st| if (st.replacement) |r| gpa.free(r);
        e.sites.deinit(gpa);
        for (e.counted.items) |r| gpa.free(r);
        e.counted.deinit(gpa);
        e.pending.deinit(gpa);
    }

    fn flushLocked(e: *Emitted) void {
        if (e.pending.items.len == 0) return;
        if (e.out) |w| {
            w.writeAll(e.pending.items) catch {};
            w.flush() catch {};
        }
        e.pending.clearRetainingCapacity();
    }
};

inline fn key(id: LintId, pos: Pos) u64 {
    return @as(u64, @backingInt(id)) << 32 | @backingInt(pos);
}

/// Writes the buffered warnings to stderr: at the end of every command,
/// before an error, and before `trace` and a warning print their own line.
/// Only the demand path prints.
pub fn flush(ev: *Evaluator) void {
    if (!ev.par.is_main) return;
    const e = &ev.shared.lints;
    e.lock.lockUncancelable(ev.io);
    defer e.lock.unlock(ev.io);
    e.flushLocked();
}

/// The text of every warning emitted so far, in order.
pub fn records(ev: *Evaluator) []const []u8 {
    return ev.shared.lints.records.items;
}

/// The site of each of `records`, null where none was looked for.
pub fn sites(ev: *Evaluator) []const ?@import("../log.zig").Site {
    return ev.shared.lints.sites.items;
}

fn seen(ev: *Evaluator, id: LintId, pos: Pos) bool {
    const k = key(id, pos);
    if (ev.local.lint_seen.contains(k)) return true;
    const e = &ev.shared.lints;
    e.lock.lockUncancelable(ev.io);
    const hit = e.seen.contains(k);
    e.lock.unlock(ev.io);
    if (hit) ev.local.lint_seen.put(ev.gpa, k, {}) catch {};
    return hit;
}

/// A site outside the scope: seen, so no fiber classifies it again.
fn silence(ev: *Evaluator, id: LintId, pos: Pos) void {
    const k = key(id, pos);
    ev.local.lint_seen.put(ev.gpa, k, {}) catch {};
    const e = &ev.shared.lints;
    e.lock.lockUncancelable(ev.io);
    defer e.lock.unlock(ev.io);
    e.seen.put(ev.gpa, k, {}) catch {};
}

/// Records the finding and queues its line; nothing when another fiber
/// recorded it first. A finding of `tree` is the one of that tree in the
/// run, with a site or without; every other finding is the one of its site.
fn record(ev: *Evaluator, id: LintId, pos: Pos, line_in: []const u8, tree: ?[]const u8) void {
    // under `--log-format internal-json` the line is a record, with the
    // site's span
    var json_line: ?[]u8 = null;
    defer if (json_line) |j| ev.config.session.?.gpa.free(j);
    var site_: ?@import("../log.zig").Site = null;
    var site_owned = false;
    defer if (site_owned) if (site_.?.replacement) |r| ev.gpa.free(r);
    const json = if (ev.config.session) |sess| sess.log.isJson() else false;
    if (json or ev.trace().isOn()) {
        var arena: std.heap.ArenaAllocator = .init(ev.gpa);
        defer arena.deinit();
        if (siteOf(ev, arena.allocator(), id, pos) catch null) |x| {
            site_ = .{ .start = x.start, .end = x.end, .replacement = if (x.replacement) |r| ev.gpa.dupe(u8, r) catch null else null };
            site_owned = true;
        }
        if (json) if (ev.config.session.?.log.lint(line_in, site_)) |r| {
            ev.config.session.?.gpa.free(r.record);
            json_line = r.shown;
        } else |_| {};
    }
    const line = json_line orelse line_in;
    const e = &ev.shared.lints;
    e.lock.lockUncancelable(ev.io);
    defer e.lock.unlock(ev.io);
    if (tree) |t| {
        for (e.counted.items) |c| if (std.mem.eql(u8, c, t)) return;
        const owned = ev.gpa.dupe(u8, t) catch return;
        e.counted.append(ev.gpa, owned) catch {
            ev.gpa.free(owned);
            return;
        };
    } else {
        const k = key(id, pos);
        ev.local.lint_seen.put(ev.gpa, k, {}) catch {};
        const gop = e.seen.getOrPut(ev.gpa, k) catch return;
        if (gop.found_existing) return;
    }
    e.pending.ensureUnusedCapacity(ev.gpa, line.len + 1) catch return;
    e.pending.appendSliceAssumeCapacity(line);
    e.pending.appendAssumeCapacity('\n');
    if (ev.gpa.dupe(u8, line_in)) |r| {
        if (e.records.append(ev.gpa, r)) {
            if (e.sites.append(ev.gpa, site_)) {
                site_owned = false;
            } else |_| if (e.records.pop()) |x| ev.gpa.free(x);
        } else |_| ev.gpa.free(r);
    } else |_| {}
    if (e.pending.items.len >= flush_at and ev.par.is_main) e.flushLocked();
}

/// A finding waiting for the demand path (`effects.deferRun`).
pub const Deferred = struct {
    id: LintId,
    pos: Pos,
    line: []u8,
    tree: ?[]u8,

    pub fn run(d: *const Deferred, ev: *Evaluator) void {
        record(ev, d.id, d.pos, d.line, d.tree);
    }

    pub fn destroy(d: *Deferred, gpa: Allocator) void {
        gpa.free(d.line);
        if (d.tree) |t| gpa.free(t);
        gpa.destroy(d);
    }
};

/// Reports a lint site: nothing at `off`, outside the scope, or on a line
/// a `# iets: allow` comment covers; one warning per (lint, pos) at
/// `warn`, an error `tryEval` does not catch at `error`. `level`, when
/// given, is that of the tree a value comes from, not of the site; a
/// finding of `tree` is one for the tree, so the site set does not see it.
pub fn site(ev: *Evaluator, id: LintId, pos: Pos, level: ?Level, tree: ?[]const u8, comptime fmt: []const u8, args: anytype) Error!void {
    const lv = gate(ev, id, pos, level, tree != null) orelse return;
    const msg = try std.fmt.allocPrint(ev.gpa, fmt, args);
    defer ev.gpa.free(msg);
    return emit(ev, id, pos, lv, msg, tree);
}

/// The level a site reports at, or null when it is silent. A site the scope
/// silences enters the site set; an `error` site never does, so every
/// fiber that reaches it fails.
noinline fn gate(ev: *Evaluator, id: LintId, pos: Pos, level: ?Level, has_tree: bool) ?Level {
    if (!has_tree and seen(ev, id, pos)) return null;
    const file = ev.files.fileOf(pos);
    if (file) |f| if (f.file.allows.covers(f.off, id)) {
        silence(ev, id, pos);
        return null;
    };
    const cfg = ev.config.lints;
    const lv = level orelse if (cfg.scoped()) cfg.siteLevel(id, whereOfFile(ev, if (file) |f| f.file else null)) else cfg.level(id);
    if (lv == .off) {
        silence(ev, id, pos);
        return null;
    }
    return lv;
}

noinline fn emit(ev: *Evaluator, id: LintId, pos: Pos, lv: Level, msg: []const u8, tree: ?[]const u8) Error!void {
    switch (lv) {
        .off => {},
        .warn => try print(ev, id, pos, msg, tree),
        .@"error" => return ev.fail(.lint, pos, "[{s}] {s}", .{ id.name(), msg }),
    }
}

/// `warning: [NAME] MSG` and `  at POS`, deferred while a helper forces
/// ahead: a helper may reach a site the program never asks for, and the
/// finding then waits for the thunk whose value carries it.
fn print(ev: *Evaluator, id: LintId, pos: Pos, msg: []const u8, tree: ?[]const u8) Error!void {
    var line: std.Io.Writer.Allocating = .init(ev.gpa);
    defer line.deinit();
    (blk: {
        line.writer.print("warning: [{s}] {s}", .{ id.name(), msg }) catch |e| break :blk e;
        if (pos != .none) {
            line.writer.writeAll("\n  at ") catch |e| break :blk e;
            writePos(ev, &line.writer, pos) catch |e| break :blk e;
        }
    }) catch return error.OutOfMemory;
    const d = try ev.gpa.create(Deferred);
    errdefer ev.gpa.destroy(d);
    const t = if (tree) |x| try ev.gpa.dupe(u8, x) else null;
    errdefer if (t) |x| ev.gpa.free(x);
    d.* = .{ .id = id, .pos = pos, .line = try line.toOwnedSlice(), .tree = t };
    effects.deferRun(ev, d);
}

/// Compile-time diagnostics, at the level the compiler saw. A file
/// compiles the same in every fiber, so a helper reports them itself
/// instead of bailing; the site set keeps them to one line each.
pub fn reportDiags(ev: *Evaluator, diags: []const Diag) Error!void {
    for (diags) |d| if (!seen(ev, d.id, d.pos)) try print(ev, d.id, d.pos, d.msg, null);
}

/// `file:line:col` of a lint site, the local path for a file inside a store
/// copy this evaluation made.
fn writePos(ev: *Evaluator, w: *std.Io.Writer, pos: Pos) !void {
    const loc = ev.files.locate(pos) orelse return w.writeAll("«none»");
    const p = try localPath(ev, loc.file.path, null);
    defer if (p.ptr != loc.file.path.ptr) ev.gpa.free(p);
    try w.print("{s}:{d}:{d}", .{ p, loc.line, loc.column });
}

/// A source path as a lint message shows it: the local path a store copy
/// stands for, like a site's position. Owned by `ev.gpa` when it differs
/// from `p`.
pub fn shownPath(ev: *Evaluator, p: []const u8) Error![]const u8 {
    return localPath(ev, p, null);
}

/// The local path a store copy stands for, through the copy chain and then
/// the `source-map` setting. `input` gets the index in the configuration of
/// the first flake tree on the way that it names.
/// Owned by `ev.gpa` when it differs from `path`.
fn localPath(ev: *Evaluator, path: []const u8, input: ?*?u32) Error![]const u8 {
    var p = path;
    var hops: u32 = 0;
    while (hops < 8) : (hops += 1) {
        const s = store_hooks.splitStorePath(p) orelse break;
        if (input) |in| if (in.* == null) if (store_hooks.flakeNamed(ev, s.base)) |name| {
            in.* = ev.config.lints.inputIndex(name);
        };
        const o = store_hooks.knownOrigin(ev, s.base) orelse break;
        const root = switch (o.src) {
            .fs => |f| f.root,
            .mem, .tree => break,
        };
        const next = if (s.rest.len == 0) try ev.gpa.dupe(u8, root) else try std.mem.concat(ev.gpa, u8, &.{ root, "/", s.rest });
        if (p.ptr != path.ptr) ev.gpa.free(p);
        p = next;
    }
    const sess = ev.config.session orelse return p;
    for (sess.settings.source_map) |m| {
        if (!std.mem.startsWith(u8, p, m.name)) continue;
        const rest = p[m.name.len..];
        if (rest.len > 0 and rest[0] != '/') continue;
        const next = try std.mem.concat(ev.gpa, u8, &.{ m.value, rest });
        if (p.ptr != path.ptr) ev.gpa.free(p);
        return next;
    }
    return p;
}

/// Where the file of `pos` lies, classified once per file and worker.
pub fn whereOf(ev: *Evaluator, pos: Pos) Where {
    const f = ev.files.fileOf(pos) orelse return .elsewhere;
    return whereOfFile(ev, f.file);
}

fn whereOfFile(ev: *Evaluator, file: ?*Files.File) Where {
    const f = file orelse return .elsewhere;
    if (ev.local.lint_where.get(f.base)) |w| return w;
    const w = whereOfPath(ev, f.path);
    ev.local.lint_where.put(ev.gpa, f.base, w) catch {};
    return w;
}

/// Where a file lies. The entry expression (`«string»`, `«arg»`) is in
/// root, the other pseudo-files are not. A store path resolves through the
/// virtual copies to the local tree it stands for; the tree of a locked
/// input the configuration names is `input`.
pub fn whereOfPath(ev: *Evaluator, path: []const u8) Where {
    if (std.mem.startsWith(u8, path, "«")) {
        const entry = std.mem.eql(u8, path, "«string»") or std.mem.eql(u8, path, "«arg»");
        return if (entry) .root else .elsewhere;
    }
    var input: ?u32 = null;
    const p = localPath(ev, path, &input) catch return .elsewhere;
    defer if (p.ptr != path.ptr) ev.gpa.free(p);
    if (ev.config.lints.inRoot(p)) return .root;
    return if (input) |i| .{ .input = i } else .elsewhere;
}

/// The lint configuration the file `path` is compiled under.
pub fn configForFile(ev: *Evaluator, path: []const u8) lint.Config {
    const cfg = ev.config.lints;
    if (!cfg.scoped()) return cfg.*;
    return cfg.forWhere(whereOfPath(ev, path));
}

/// The byte span of the site of `id` at `pos` and its edit
/// (`site.finding`), from a second parse of the file: the IR keeps where a
/// node starts, not where it ends. The parse is kept on the file for its
/// next finding. Null for a source that is not a file, such as `-E`. The
/// edit is in `a`.
// The internal-json record of a finding carries this, an error's too.
pub fn siteOf(ev: *Evaluator, a: Allocator, id: LintId, pos: Pos) Error!?lint.site.Site {
    const f = ev.files.fileOf(pos) orelse return null;
    const parsed = (try parsedOf(ev, f.file)) orelse return null;
    return lint.site.finding(a, parsed.src, &parsed.tree, id, f.off);
}

/// The file's source and its parse, made once; never changed after.
fn parsedOf(ev: *Evaluator, file: *Files.File) Error!?*const Files.File.Parsed {
    file.parse_lock.lockUncancelable(ev.io);
    defer file.parse_lock.unlock(ev.io);
    if (file.parsed) |*p| return p;
    if (file.parse_failed or std.mem.startsWith(u8, file.path, "«")) return null;
    const gpa = ev.files.gpa;
    var failed: store_hooks.Failed = undefined;
    const sp = try store_hooks.resolve(ev, file.path);
    const src = sp.read(ev, gpa, true, &failed) catch |e| switch (e) {
        error.IoFailed => {
            file.parse_failed = true;
            return null;
        },
        else => |x| return x,
    };
    errdefer gpa.free(src);
    const syntax = @import("../syntax.zig");
    var dg: syntax.Diag = .init(gpa);
    defer dg.deinit();
    var at: u32 = 0;
    const tree = syntax.parse(gpa, src, @fromBackingInt(0), ev.interner, &dg, &at) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            gpa.free(src);
            file.parse_failed = true;
            return null;
        },
    };
    file.parsed = .{ .src = src, .tree = tree };
    return &file.parsed.?;
}

/// The lock node name of the flake root or locked input whose tree `path`
/// lies in, when the entry is a flake.
pub fn flakeTreeOf(ev: *Evaluator, path: []const u8) ?[]const u8 {
    return store_hooks.flakeOf(ev, path);
}
