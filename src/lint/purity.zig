//! Purity and reproducibility: impure builtins, unhashed fetches, import
//! from derivation, fixed-output derivations, large or git-bearing source
//! copies, paths and tree metadata in derivation attributes. Hook: the
//! evaluator at the call; `currentTime` is a constant the globals hold, with
//! no position of its own, so the compiler reports the reference.

const std = @import("std");
const lint = @import("../lint.zig");
const LintId = lint.LintId;
const Level = lint.Level;
const Where = lint.Where;
const report = lint.report;
const Evaluator = @import("../eval/Evaluator.zig");
const Error = Evaluator.Error;
const Pos = @import("../syntax/pos.zig").Pos;
const value = @import("../runtime/value.zig");
const Value = value.Value;
const Ctx = value.Ctx;
const store_hooks = @import("../builtins/store_hooks.zig");

pub const current_time_msg = "`currentTime` is impure: the result changes with every run";

/// A reference to the global `name` is `currentTime`.
pub fn isCurrentTime(name: []const u8) bool {
    const n = if (std.mem.startsWith(u8, name, "__")) name[2..] else name;
    return std.mem.eql(u8, n, "currentTime");
}

pub fn getEnv(ev: *Evaluator, name: []const u8, pos: Pos) Error!void {
    return ev.lint(.impure_builtin, pos, "`getEnv \"{s}\"` is impure: the result depends on the environment", .{name});
}

const hash_attrs = [_][]const u8{ "sha256", "hash", "narHash", "rev", "outputHash" };

/// A fetcher call: `arg` is a URL string or an attrset; either way a hash
/// (or a `rev`) must pin the result.
pub fn unhashedFetch(ev: *Evaluator, builtin: []const u8, arg: Value, pos: Pos) Error!void {
    if (!ev.lintOn(.unhashed_fetch)) return;
    const w = try ev.force(arg);
    const pinned = switch (w.typeOf()) {
        .set => blk: {
            const a = try ev.forceAttrs(w, pos, "");
            for (a.attrs()) |at| {
                const n = ev.interner.name(at.sym);
                for (hash_attrs) |h| if (std.mem.eql(u8, n, h)) break :blk true;
            }
            break :blk false;
        },
        .string => false,
        else => return,
    };
    if (pinned) return;
    return ev.lint(.unhashed_fetch, pos, "`{s}` is called without a hash, narHash or rev: the result is not reproducible", .{builtin});
}

/// `import` of a string whose context names a derivation.
pub fn ifd(ev: *Evaluator, ctx: []const Ctx, pos: Pos) Error!void {
    if (!ev.lintOn(.ifd)) return;
    const drv = for (ctx) |c| switch (c.kind) {
        .drv_deep => break c.path,
        // the `.drv` at the bottom of the chain is the one to build first
        .built => break if (std.mem.lastIndexOfScalar(u8, c.path, '!')) |i| c.path[i + 1 ..] else c.path,
        .opaque_path, .impure_path, .impure_meta => {},
    } else return;
    return ev.lint(.ifd, pos, "import from derivation: this import needs '{s}' built first", .{drv});
}

/// A read of `out`, a derivation output found in this machine's store.
pub fn ifdLocalOutput(ev: *Evaluator, out: []const u8, pos: Pos) Error!void {
    return ev.lint(.ifd_local_output, pos, "import from derivation: '{s}' is read from this machine's store; where it is missing, the evaluation builds it or fails", .{out});
}

pub fn fod(ev: *Evaluator, name: []const u8, mode: []const u8, algo: []const u8, pos: Pos) Error!void {
    return ev.lint(.fod, pos, "derivation '{s}' is fixed-output ({s}, {s})", .{ name, mode, algo });
}

/// A recursive copy of `path` whose NAR has `size` bytes.
pub fn largeSourceCopy(ev: *Evaluator, path: []const u8, size: u64, pos: Pos) Error!void {
    if (!ev.lintOn(.large_source_copy)) return;
    const max = ev.config.lints.max_bytes;
    if (size <= max) return;
    const shown = try report.shownPath(ev, path);
    defer if (shown.ptr != path.ptr) ev.gpa.free(shown);
    return ev.lint(.large_source_copy, pos, "copying '{s}' to the store takes {d} bytes of NAR, over the {d} byte limit; filter the source", .{ shown, size, max });
}

/// A string coercion copied the directory `path` whole: no filter, and not
/// a tree the flake machinery already turned into a tracked file set.
pub fn dirCopyUnfiltered(ev: *Evaluator, path: []const u8, pos: Pos) Error!void {
    return ev.lint(.dir_copy_unfiltered, pos, "directory '{s}' is copied to the store whole, untracked and ignored files included; use `builtins.path {{ path = ...; filter = ...; }}`", .{path});
}

/// A recursive copy of `path` whose top level holds a `.git` entry.
pub fn gitInSource(ev: *Evaluator, path: []const u8, pos: Pos) Error!void {
    return ev.lint(.git_in_source, pos, "copying '{s}' to the store includes its `.git` entry; filter the source or use a git fetcher", .{path});
}

/// The nearest project root at or above `path` (`project.zig`). Every probe
/// is a `Stat` observation, so a new marker is a cache miss. No probe is
/// remembered for the run: the read set's dedupe keeps one observation per
/// marker, and a lint is rare enough to stat again.
fn projectRootOf(ev: *Evaluator, path: []const u8) bool {
    var scratch: std.heap.ArenaAllocator = .init(ev.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const dir = Evaluator.canonPath(a, path) catch return false;
    return @import("../project.zig").findWith(dir, ev, probe) != null;
}

fn probe(ev: *Evaluator, dir: []const u8, marker: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ dir, if (std.mem.endsWith(u8, dir, "/")) "" else "/", marker }) catch return false;
    return ev.trace().statNow(p, true) != .missing;
}

/// Derivation `drv_name` received attribute `key` whose value carries the
/// text of the non-store path `path`: `absolute-path-in-drv` under a
/// project root, `impure-path-in-drv` elsewhere.
fn pathInDrv(ev: *Evaluator, drv_name: []const u8, key: []const u8, path: []const u8, attr_pos: Pos) Error!void {
    // the root is not in the message: it is the working tree, which the
    // reader is in, and naming it makes the text differ per checkout
    if (projectRootOf(ev, path))
        return ev.lint(.absolute_path_in_drv, attr_pos, "derivation '{s}': attribute '{s}' holds the absolute path '{s}' of this project; interpolate the path to copy it, or pass a relative name", .{ drv_name, key, path });
    return ev.lint(.impure_path_in_drv, attr_pos, "derivation '{s}': attribute '{s}' holds the checkout path '{s}', so the .drv depends on where the repository lives; interpolate the path to copy it to the store", .{ drv_name, key, path });
}

/// The level of `id`, a lint on the metadata of a tree, for the tree
/// `source`: `self`, or `inputs.<node>` by lock node name. The tree a value
/// comes from decides, not the site: a locked input changes at a lock
/// update only, so it follows the scope rule like a site outside the roots.
pub fn treeLevel(ev: *const Evaluator, id: LintId, source: []const u8) Level {
    // classic mode lints nothing, the trees' metadata included
    if (ev.config.lints == &lint.Config.off) return .off;
    const cfg = ev.config.lints;
    const w: Where = if (std.mem.startsWith(u8, source, "inputs.")) blk: {
        const node = source["inputs.".len..];
        break :blk if (cfg.inputIndex(node)) |i| .{ .input = i } else .elsewhere;
    } else .root;
    return cfg.siteLevel(id, w);
}

/// The evaluation reads `revCount` of the tree `source`. `pos` is the
/// selection, or `.none` when the read forced the lazy value: native code
/// made that value and the evaluator keeps no call trace, so that finding
/// has no site and the message alone names the tree.
pub fn revCount(ev: *Evaluator, source: []const u8, pos: Pos) Error!void {
    const level = treeLevel(ev, .rev_count, source);
    return report.site(ev, .rev_count, pos, level, source, "'{s}.revCount' is deprecated: the count of all revisions is expensive to compute and absent on a shallow clone, and iets plans to remove it; use 'lastModifiedDate' and 'shortRev' for a version", .{source});
}

/// The marks in `ctx`, the context that the value of attribute `key` gave
/// derivation `drv_name`. The tree metadata (`self.rev`) is one finding
/// that names them all, at the strictest of their levels. The level comes
/// from the tree, so with `site` `.none` the finding goes to `attr_pos`,
/// in scope or not. `derivationStrict` tests each attribute of each
/// derivation: the report stays out of that loop.
pub noinline fn marksInDrv(ev: *Evaluator, drv_name: []const u8, key: []const u8, ctx: []const Ctx, site_pos: Pos, attr_pos: Pos) Error!void {
    @branchHint(.cold);
    const paths = ev.lintOn(.impure_path_in_drv) or ev.lintOn(.absolute_path_in_drv);
    var metas: std.ArrayList([]const u8) = .empty;
    defer metas.deinit(ev.gpa);
    for (ctx) |c| switch (c.kind) {
        .impure_path => if (paths) try pathInDrv(ev, drv_name, key, c.path, site_pos),
        .impure_meta => try metas.append(ev.gpa, c.path),
        else => {},
    };
    if (metas.items.len == 0) return;
    std.mem.sort([]const u8, metas.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    var n: usize = 0;
    for (metas.items) |m| {
        if (n > 0 and std.mem.eql(u8, metas.items[n - 1], m)) continue;
        metas.items[n] = m;
        n += 1;
    }
    metas.shrinkRetainingCapacity(n);
    var level: Level = .off;
    var any_self = false;
    for (metas.items) |m| {
        const src = if (std.mem.lastIndexOfScalar(u8, m, '.')) |i| m[0..i] else m;
        const l = treeLevel(ev, .tree_meta_in_drv, src);
        if (@backingInt(l) > @backingInt(level)) level = l;
        any_self = any_self or std.mem.startsWith(u8, m, "self.");
    }
    const at = if (site_pos == .none) attr_pos else site_pos;
    const when = if (any_self) "commit or edit" else "update of the lock file";
    return report.site(ev, .tree_meta_in_drv, at, level, null, "derivation '{s}': attribute '{s}' holds '{f}', a value that changes with every {s}, so this derivation and all that depend on it are built again each time; keep the value out of the build, or read it at run time", .{ drv_name, key, Joined{ .items = metas.items }, when });
}

const Joined = struct {
    items: []const []const u8,

    pub fn format(j: Joined, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (j.items, 0..) |m, i| {
            if (i > 0) try w.writeAll("', '");
            try w.writeAll(m);
        }
    }
};

/// A selection at `pos` reads `cell` under the name `revCount`. When the
/// cell holds the lazy count of a tree, the finding goes to `pos` and the
/// count is computed here. The thunk stays unforced on purpose: it names
/// its tree for the next selection, which a plain integer cannot, and a
/// read that is not a selection still reports when it forces the thunk.
pub fn countRead(ev: *Evaluator, cell: *value.Cell, pos: Pos) Error!Value {
    const w = cell.get();
    if (w.tag() == .thunk_app) {
        const t = w.untagged(value.Thunk);
        // `code` before `state`: a force takes the state first and puts the
        // value in `code` after, so an unforced state proves the function
        const f = t.code.get();
        const of = t.state.get();
        const unforced = !(of.isBlackhole() or of == .empty or of == .speculated or of == .speculated_fx);
        if (unforced and @import("../builtins/fetch.zig").isCount(f)) {
            const app = f.view().primop_app;
            const tree = app.args()[0];
            if (tree.kind() == .string) {
                try revCount(ev, tree.as(value.String).bytes(), pos);
                return ev.apply(.fromPtr(.ptr, app.op), &.{ .null, of }, pos);
            }
        }
    }
    return ev.forceCell(cell);
}
