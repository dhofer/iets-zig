//! Silent coercions: path copies, reads through a copy, derivation
//! attribute coercions, `==` across types or on functions, `or` on a
//! non-attrset. Hook: the evaluator, at the coercion site.

const std = @import("std");
const lint = @import("../lint.zig");
const LintId = lint.LintId;
const report = lint.report;
const Evaluator = @import("../eval/Evaluator.zig");
const Error = Evaluator.Error;
const Pos = @import("../syntax/pos.zig").Pos;
const value = @import("../runtime/value.zig");
const Value = value.Value;
const store_hooks = @import("../builtins/store_hooks.zig");
const store_path = @import("../store/path.zig");

/// After a path was copied to the store by a string coercion. Inside a
/// flake root or a locked input `"${./file}"` is the normal reference: a
/// file is silent, a directory is `dir-copy-flake`, not `path-copy`.
pub fn pathCopy(ev: *Evaluator, path: []const u8, sp: []const u8, pos: Pos) Error!void {
    if (!ev.lintOn(.path_copy) and !ev.lintOn(.dir_copy_flake)) return;
    const shown = try report.shownPath(ev, path);
    defer if (shown.ptr != path.ptr) ev.gpa.free(shown);
    if (report.flakeTreeOf(ev, path) != null) {
        if (!ev.lintOn(.dir_copy_flake) or (store_hooks.stat(ev, path, true) catch .missing) != .directory) return;
        return ev.lint(.dir_copy_flake, pos, "directory '{s}' of the flake tree is copied to the store as '{s}' by this string coercion: the tracked files, as the flake machinery kept them; use `lib.fileset.toSource` or `builtins.path {{ path = ...; filter = ...; }}` only to narrow it further", .{ shown, sp });
    }
    return ev.lint(.path_copy, pos, "path '{s}' is copied to the store as '{s}' by this string coercion; use `toString` for the name or `builtins.path` for an explicit copy", .{ shown, sp });
}

/// Before `path` is copied: a path that already lies under the store dir,
/// unless it is the flake root's or a locked input's virtual copy.
pub fn storePathRecopy(ev: *Evaluator, path: []const u8, pos: Pos) Error!void {
    if (!ev.lintOn(.store_path_recopy)) return;
    const dir = ev.store_dir;
    if (!(path.len > dir.len and std.mem.startsWith(u8, path, dir) and path[dir.len] == '/')) return;
    if (report.flakeTreeOf(ev, path) != null) return;
    return ev.lint(.store_path_recopy, pos, "'{s}' is already a store path and is copied again, which doubles the hash in its name; use `builtins.storePath` or keep it a string", .{path});
}

/// A read of `path` (readFile, readDir, import, ...) that goes through a
/// store copy this evaluation made.
pub fn readThroughCopy(ev: *Evaluator, path: []const u8, pos: Pos) Error!void {
    if (!ev.lintOn(.read_through_copy)) return;
    const s = store_hooks.splitStorePath(path) orelse return;
    const o = store_hooks.knownOrigin(ev, s.base) orelse return;
    if (!o.copy) return;
    const root = path[0 .. path.len - s.rest.len - @intFromBool(s.rest.len > 0)];
    const local = store_hooks.copiedFrom(ev, root);
    return ev.lint(.read_through_copy, pos, "'{s}' is read through the store copy '{s}'{f}; read the original path instead", .{ path, root, CopiedFrom{ .local = local } });
}

const CopiedFrom = struct {
    local: ?[]const u8,

    pub fn format(c: CopiedFrom, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (c.local) |l| try w.print(" (copied from '{s}')", .{l});
    }
};

/// Where the value lints on derivation attributes (`impure-path-in-drv`,
/// `absolute-path-in-drv`, `fod`) fall back to when the attribute's
/// position is out of scope: a wrapper such as `mkDerivation` binds the
/// attribute, but the value is the user's. The `derivationStrict` call, the
/// `name` attribute, then the first attribute whose position lies in a lint
/// root, else `.none`. There is no call trace, so a derivation with no
/// position from the root (a nixpkgs fetcher call) stays silent.
pub fn drvFallback(ev: *Evaluator, attrs: *value.Attrs, pos: Pos, name_pos: Pos) Pos {
    if (!ev.config.lints.scoped()) return .none;
    for ([_]Pos{ pos, name_pos }) |p| if (report.whereOf(ev, p) == .root) return p;
    // by source position: the attribute order is the symbols', which says
    // nothing about the file
    var best: Pos = .none;
    for (attrs.attrs()) |a| {
        if (report.whereOf(ev, a.pos) != .root) continue;
        if (best == .none or @backingInt(a.pos) < @backingInt(best)) best = a.pos;
    }
    return best;
}

/// The site of the derivation itself, for the encoding lints
/// (`drv-bool-null`, `drv-list`): the `derivationStrict` call when the
/// scope sees it, else the `builder` attribute's position, because
/// `derivation` is a wrapper in `«derivation-internal»`. Null when the
/// scope sees neither: a wrapper out of scope, such as `mkDerivation`,
/// made the derivation, and a list or Boolean there is the wrapper's
/// contract, not a coercion the user chose.
pub fn drvOwner(ev: *Evaluator, pos: Pos, builder_pos: Pos) ?Pos {
    if (!ev.config.lints.scoped()) return pos;
    for ([_]Pos{ pos, builder_pos }) |p| if (report.whereOf(ev, p) != .elsewhere) return p;
    return null;
}

/// The site a derivation-attribute lint reports at: the attribute's own
/// position when the scope keeps it, else `fallback`.
pub fn drvAttrPos(ev: *Evaluator, attr_pos: Pos, fallback: Pos) Pos {
    if (!ev.config.lints.scoped() or report.whereOf(ev, attr_pos) != .elsewhere) return attr_pos;
    return fallback;
}

/// Nix's own Boolean derivation attributes: their `"1"`/`""` encoding is
/// the protocol, so `drv-bool-null` never reports them.
const protocol_bools = [_][]const u8{
    "__structuredAttrs",
    "__ignoreNulls",
    "__impureHostDeps",
    "__propagatedImpureHostDeps",
    "__sandboxProfile",
    "__noChroot",
    "__darwinAllowLocalNetworking",
    "allowSubstitutes",
    "preferLocalBuild",
};

/// A derivation attribute value, forced, about to be coerced into the
/// environment.
pub fn drvValue(ev: *Evaluator, key: []const u8, v: Value, attr_pos: Pos) Error!void {
    switch (v.typeOf()) {
        .bool, .null => {
            for (protocol_bools) |p| if (std.mem.eql(u8, p, key)) return;
            if (v == .null)
                return ev.lint(.drv_bool_null, attr_pos, "derivation attribute '{s}' is null, which becomes \"\" in the environment; set `__ignoreNulls` to drop it", .{key});
            const b = v == .true;
            return ev.lint(.drv_bool_null, attr_pos, "derivation attribute '{s}' is the Boolean {s}, which becomes \"{s}\" in the environment", .{ key, if (b) "true" else "false", if (b) "1" else "" });
        },
        .list => if (!std.mem.eql(u8, key, "outputs"))
            return ev.lint(.drv_list, attr_pos, "derivation attribute '{s}' is a list, which is space-joined into one environment string", .{key}),
        else => {},
    }
}

/// `==` or `!=` on the forced operands `a` and `b`. A `null` on either
/// side is the language's test for absence, so it is no mismatch.
pub noinline fn eq(ev: *Evaluator, a: Value, b: Value, pos: Pos) Error!void {
    const ta = a.typeOf();
    const tb = b.typeOf();
    if (ta == .lambda or tb == .lambda)
        try ev.lint(.eq_function, pos, "`==` on a function is never true: functions compare by identity of one temporary", .{});
    const numeric = struct {
        fn f(t: value.Type) bool {
            return t == .int or t == .float;
        }
    }.f;
    const is_null = ta == .null or tb == .null;
    if (ta != tb and !is_null and !(numeric(ta) and numeric(tb)))
        try ev.lint(.eq_type_mismatch, pos, "`==` compares {s} with {s}: values of different types are never equal, so the result is constant", .{ ta.show(), tb.show() });
}

/// `x.a or d` reached a subject that is not an attrset.
pub noinline fn orNonAttrs(ev: *Evaluator, v: Value, pos: Pos) Error!void {
    return ev.lint(.or_non_attrs, pos, "`or` falls back because the subject is {s}, not an attrset", .{v.typeOf().show()});
}

test {
    _ = store_path;
}
