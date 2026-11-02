//! One installable: the attribute paths a fragment names, the values they
//! select, and the derivations those values become (docs/reference/plumbing.md).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Evaluator = @import("../eval/Evaluator.zig");
const Error = Evaluator.Error;
const value = @import("../runtime/value.zig");
const Value = value.Value;
const Attrs = value.Attrs;
const Diag = @import("../diag.zig").Diag;
const StorePath = @import("../store/path.zig").StorePath;
const derivation = @import("../builtins/derivation.zig");
const strings = @import("../builtins/strings.zig");

/// One derivation and the output its string context named, if any.
pub const DrvRoot = struct { drv: StorePath, output: ?[]const u8 = null };

/// One derivation and one of its outputs a command asked for.
pub const Root = struct { drv: StorePath, output: []const u8 };

/// Which `getActualAttrPaths` table a fragment is tried against
/// (installable-flake.cc, with each command's own defaults and prefixes).
pub const Prefixes = enum {
    /// `nix build`, `nix eval`: one package.
    package,
    /// `nix develop`, `print-dev-env`: a development shell first.
    dev_shell,
    /// `nix search`: the package sets, not one package.
    package_set,

    pub fn parse(s: []const u8) ?Prefixes {
        if (std.mem.eql(u8, s, "package")) return .package;
        if (std.mem.eql(u8, s, "dev-shell")) return .dev_shell;
        if (std.mem.eql(u8, s, "package-set")) return .package_set;
        return null;
    }
};

/// The attribute paths `fragment` names, in order. A leading `.` makes the
/// rest the whole path; an empty fragment takes the defaults. In `a`.
pub fn attrPaths(a: Allocator, p: Prefixes, fragment: []const u8, system: []const u8) ![]const []const u8 {
    var v: std.ArrayList([]const u8) = .empty;
    if (fragment.len > 0 and fragment[0] == '.') {
        try v.append(a, fragment[1..]);
        return v.items;
    }
    const f = std.fmt.allocPrint;
    if (fragment.len == 0) {
        switch (p) {
            .package => try v.appendSlice(a, &.{ try f(a, "packages.{s}.default", .{system}), try f(a, "defaultPackage.{s}", .{system}) }),
            .dev_shell => try v.appendSlice(a, &.{
                try f(a, "devShells.{s}.default", .{system}),
                try f(a, "devShell.{s}", .{system}),
                try f(a, "packages.{s}.default", .{system}),
                try f(a, "defaultPackage.{s}", .{system}),
            }),
            .package_set => try v.appendSlice(a, &.{ try f(a, "packages.{s}", .{system}), try f(a, "legacyPackages.{s}", .{system}) }),
        }
        return v.items;
    }
    if (p == .dev_shell) try v.append(a, try f(a, "devShells.{s}.{s}", .{ system, fragment }));
    try v.append(a, try f(a, "packages.{s}.{s}", .{ system, fragment }));
    try v.append(a, try f(a, "legacyPackages.{s}.{s}", .{ system, fragment }));
    try v.append(a, fragment);
    return v.items;
}

/// installable-flake.cc:showAttrPaths.
pub fn showAttrPaths(w: *std.Io.Writer, paths: []const []const u8) std.Io.Writer.Error!void {
    for (paths, 0..) |p, n| {
        if (n > 0) try w.writeAll(if (n + 1 == paths.len) " or " else ", ");
        try w.print("'{s}'", .{p});
    }
}

/// Mirrors attr-path.cc:parseAttrPath: `a.b."c.d"`. An unclosed quote is an error,
/// whose message `d` holds.
pub fn parseAttrPath(a: Allocator, s: []const u8, d: *Diag) ![]const []const u8 {
    var res: std.ArrayList([]const u8) = .empty;
    var cur: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '.' => {
                try res.append(a, try cur.toOwnedSlice(a));
            },
            '"' => {
                i += 1;
                while (true) : (i += 1) {
                    if (i >= s.len) return d.fail(error.Flake, "missing closing quote in selection path '{s}'", .{s});
                    if (s[i] == '"') break;
                    try cur.append(a, s[i]);
                }
            },
            else => |c| try cur.append(a, c),
        }
    }
    if (cur.items.len > 0) try res.append(a, cur.items);
    return res.items;
}

/// attr-path.cc:findAlongAttrPath. Auto-calls at every step, selects an
/// attribute by name or a list element by index. Every command that takes
/// `-A` goes through this, so a file whose top level is a function is called
/// with `--arg`/`--argstr` the same way everywhere
/// (docs/reference/commands.md).
/// A candidate that resolved: the value and the attribute path it was at.
pub const Found = struct { value: Value, path: []const u8 };

/// The candidates of `fragment` selected from a flake's `outputs`. Never
/// empty: a miss is `missing_attr` naming every candidate, as Nix reports
/// it.
pub fn fromOutputs(ev: *Evaluator, a: Allocator, outputs: Value, loc: []const u8, p: Prefixes, fragment: []const u8, want_all: bool) Error![]const Found {
    const candidates = try attrPaths(a, p, fragment, ev.config.system);
    var found: std.ArrayList(Found) = .empty;
    var d: Diag = .init(a);
    for (candidates) |c| {
        const path = @import("../flake.zig").parseAttrPath(a, c, &d) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return ev.fail(.eval, .none, "{s}", .{d.message()}),
        };
        if (try @import("../flake.zig").select(ev, outputs, path)) |v| {
            try found.append(a, .{ .value = v, .path = try std.mem.join(a, ".", path) });
            if (!want_all) return found.items;
        }
    }
    if (found.items.len == 0) {
        var shown: std.Io.Writer.Allocating = .init(a);
        showAttrPaths(&shown.writer, candidates) catch return error.OutOfMemory;
        return ev.fail(.missing_attr, .none, "flake '{s}' does not provide attribute {s}", .{ loc, shown.written() });
    }
    return found.items;
}

pub fn findAlongAttrPath(ev: *Evaluator, root: Value, attr_path: []const u8, args: *Attrs) Error!Value {
    var arena: std.heap.ArenaAllocator = .init(ev.gpa);
    defer arena.deinit();
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    const path = parseAttrPath(arena.allocator(), attr_path, &d) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return ev.fail(.parse, .none, "{s}", .{d.message()}),
    };
    var v = root;
    for (path) |attr| {
        v = try ev.force(try ev.autoCall(v, args));
        if (std.fmt.parseInt(u32, attr, 10)) |idx| {
            if (v.kind() != .list)
                return ev.fail(.type, .none, "the expression selected by the selection path '{s}' should be a list", .{attr_path});
            const cells = v.as(value.List).cells();
            if (idx >= cells.len)
                return ev.fail(.missing_attr, .none, "list index {d} in selection path '{s}' is out of range", .{ idx, attr_path });
            v = cells[idx].get();
        } else |_| {
            if (v.kind() != .attrs)
                return ev.fail(.type, .none, "the expression selected by the selection path '{s}' should be a set", .{attr_path});
            if (attr.len == 0)
                return ev.fail(.eval, .none, "empty attribute name in selection path '{s}'", .{attr_path});
            const at = v.as(Attrs).get(try ev.sym(attr)) orelse
                return ev.fail(.missing_attr, .none, "attribute '{s}' in selection path '{s}' not found", .{ attr, attr_path });
            v = at.cell.get();
        }
    }
    return v;
}

/// The `-A` completion of `prefix` under the root `in`: every child name of
/// the set the path before the last dot selects, that starts with the rest.
/// Sorted, in `a`.
pub fn completeInInput(ev: *Evaluator, a: Allocator, in: @import("../api.zig").Input, prefix: []const u8, cwd: []const u8) Error![]const []const u8 {
    const import_ = @import("../eval/import.zig");
    const root = switch (in) {
        .expr => |e| try import_.evalString(ev, e),
        .file => |f| try import_.evalFile(ev, @import("../api.zig").absPath(a, cwd, f) catch return error.OutOfMemory, .none),
        .flake => return &.{},
    };
    const args = try @import("../api.zig").autoArgs(ev, a, &.{});
    return completeAttrPath(ev, a, root, args, prefix);
}

/// The completion of `FLAKEREF#fragment`'s fragment under the flake at
/// `loc`: the names one level down from
/// what the fragment selects, under each prefix `p` tries.
pub fn completeInFlake(ev: *Evaluator, a: Allocator, loc: []const u8, p: Prefixes, fragment: []const u8, cwd: []const u8) Error![]const []const u8 {
    const api_flake = @import("flake.zig");
    var d: Diag = .init(a);
    const fr = api_flake.flakeRef(a, ev.io, loc, cwd, &d) catch return &.{};
    const outputs = try api_flake.outputs(ev, &fr);
    return completeFragment(ev, a, outputs, p, fragment);
}

/// Names with a dot or a quote in them are left out: nothing quotes them.
fn completeFragment(ev: *Evaluator, a: Allocator, outputs: Value, p: Prefixes, fragment: []const u8) Error![]const []const u8 {
    const flake = @import("../flake.zig");
    if (std.mem.indexOfScalar(u8, fragment, '"') != null) return &.{};
    const lead: []const u8 = if (std.mem.startsWith(u8, fragment, ".")) "." else "";
    const rest = fragment[lead.len..];
    const system = ev.config.system;
    var prefixes: std.ArrayList([]const u8) = .empty;
    if (lead.len == 0) {
        if (p == .dev_shell) try prefixes.append(a, try std.fmt.allocPrint(a, "devShells.{s}.", .{system}));
        try prefixes.append(a, try std.fmt.allocPrint(a, "packages.{s}.", .{system}));
        try prefixes.append(a, try std.fmt.allocPrint(a, "legacyPackages.{s}.", .{system}));
    }
    try prefixes.append(a, "");
    const split = if (std.mem.lastIndexOfScalar(u8, rest, '.')) |i| i + 1 else 0;
    const head = rest[0..split];
    const last = rest[split..];
    var out: std.ArrayList([]const u8) = .empty;
    for (prefixes.items) |prefix| {
        const dir = try std.mem.concat(a, u8, &.{ prefix, head });
        var d: Diag = .init(a);
        const path = flake.parseAttrPath(a, std.mem.trimEnd(u8, dir, "."), &d) catch continue;
        const v = (flake.select(ev, outputs, path) catch {
            ev.clearFailure();
            continue;
        }) orelse continue;
        const forced = ev.force(v) catch {
            ev.clearFailure();
            continue;
        };
        if (forced.kind() != .attrs) continue;
        try childNames(ev, a, forced.as(Attrs), last, &out, &.{ lead, head });
    }
    return sortedUnique(out.items);
}

/// The names in `attrs` that start with `last` and need no quoting, each
/// after `pre`.
fn childNames(ev: *Evaluator, a: Allocator, attrs: *Attrs, last: []const u8, out: *std.ArrayList([]const u8), pre: []const []const u8) !void {
    for (attrs.attrs()) |*at| {
        const n = ev.interner.name(at.sym);
        if (!std.unicode.utf8ValidateSlice(n)) continue;
        if (!std.mem.startsWith(u8, n, last) or std.mem.indexOfAny(u8, n, ".\"") != null) continue;
        var parts: std.ArrayList([]const u8) = .empty;
        try parts.appendSlice(a, pre);
        try parts.append(a, n);
        try out.append(a, try std.mem.concat(a, u8, parts.items));
    }
}

fn sortedUnique(items: [][]const u8) []const []const u8 {
    std.mem.sort([]const u8, items, {}, lessStr);
    var n: usize = 0;
    for (items) |x| {
        if (n > 0 and std.mem.eql(u8, items[n - 1], x)) continue;
        items[n] = x;
        n += 1;
    }
    return items[0..n];
}

fn completeAttrPath(ev: *Evaluator, a: Allocator, root: Value, args: *Attrs, prefix: []const u8) Error![]const []const u8 {
    if (std.mem.indexOfScalar(u8, prefix, '"') != null) return &.{};
    const split = if (std.mem.lastIndexOfScalar(u8, prefix, '.')) |i| i + 1 else 0;
    const head = prefix[0..split];
    const last = prefix[split..];
    const dir = std.mem.trimEnd(u8, head, ".");
    var v = if (dir.len == 0) root else try findAlongAttrPath(ev, root, dir, args);
    v = try ev.force(try ev.autoCall(v, args));
    if (v.kind() != .attrs) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    try childNames(ev, a, v.as(Attrs), last, &out, &.{head});
    return sortedUnique(out.items);
}

fn parseDrv(ev: *Evaluator, p: []const u8) Error!StorePath {
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    return StorePath.parse(p, &d) catch ev.fail(.eval, .none, "{s}", .{d.message()});
}

fn forcedString(ev: *Evaluator, v: Value, ctx: []const u8) Error![]const u8 {
    return (try ev.forceString(v, .none, ctx)).bytes();
}

/// A list of strings, `not_list` when the value is something else; in `a`.
fn stringList(ev: *Evaluator, a: Allocator, v: Value, not_list: []const u8, ctx: []const u8) Error![]const []const u8 {
    const w = try ev.force(v);
    if (w.kind() != .list) return ev.fail(.type, .none, "{s}", .{not_list});
    const cells = w.as(value.List).cells();
    const out = try a.alloc([]const u8, cells.len);
    for (cells, out) |*c, *o| o.* = try forcedString(ev, c.get(), ctx);
    return out;
}

/// `type = "derivation"`, the test both the get-drvs walk and the output
/// selection start from.
fn isDerivation(ev: *Evaluator, attrs: *Attrs) Error!bool {
    const t = attrs.get(ev.s.type) orelse return false;
    return std.mem.eql(u8, try forcedString(ev, t.cell.get(), "while evaluating the 'type' attribute"), "derivation");
}

/// The `drvPath` of a derivation attrset.
fn drvOf(ev: *Evaluator, attrs: *Attrs) Error!StorePath {
    const dp = attrs.get(ev.s.drvPath) orelse return ev.fail(.missing_attr, .none, "derivation without a 'drvPath' attribute", .{});
    return parseDrv(ev, (try ev.forceString(dp.cell.get(), .none, "while evaluating 'drvPath'")).bytes());
}

/// The `outputName` of a derivation attrset.
fn outputName(ev: *Evaluator, attrs: *Attrs, drv: *const StorePath) Error![]const u8 {
    const on = attrs.get(ev.s.outputName) orelse
        return ev.fail(.missing_attr, .none, "derivation '{f}' lacks an 'outputName' attribute", .{drv});
    return forcedString(ev, on.cell.get(), "while evaluating 'outputName'");
}

/// The derivations a build result names: an attrset with `drvPath`, a string
/// with derivation context, or a list of those. `!out!drv` context also names
/// the wanted output. `roots` grows in `a`.
pub fn drvRoots(ev: *Evaluator, a: Allocator, v_in: Value, roots: *std.ArrayList(DrvRoot)) Error!void {
    const v = try ev.force(v_in);
    switch (v.kind() orelse .int) {
        .attrs => {
            const attrs = v.as(Attrs);
            if (attrs.get(ev.s.drvPath) == null)
                return ev.fail(.eval, .none, "expression evaluated to an attrset without 'drvPath'", .{});
            const p = try drvOf(ev, attrs);
            if (!p.isDerivation()) return ev.fail(.eval, .none, "'{f}' is not a derivation path", .{&p});
            try roots.append(a, .{ .drv = p });
        },
        .string => {
            const s = v.as(value.String);
            var found = false;
            for (s.context()) |c| switch (c.kind) {
                .built => {
                    if (std.mem.indexOfScalar(u8, c.path, '!') != null)
                        return ev.fail(.eval, .none, "iets: the output of a dynamic derivation is not an installable", .{});
                    try roots.append(a, .{ .drv = try parseDrv(ev, c.path), .output = try a.dupe(u8, c.output) });
                    found = true;
                },
                .drv_deep => {
                    try roots.append(a, .{ .drv = try parseDrv(ev, c.path) });
                    found = true;
                },
                else => {},
            };
            if (!found) return ev.fail(.eval, .none, "string '{s}' has no derivation in its context", .{s.bytes()});
        },
        .list => for (v.as(value.List).cells()) |*c| try drvRoots(ev, a, c.get(), roots),
        else => return ev.fail(.eval, .none, "expression must evaluate to a derivation, a string with derivation context, or a list of those", .{}),
    }
}

/// What `iets build` builds. A derivation, a string with derivation context
/// or a list is `drvRoots`. Any other attrset is a tree for `getDrvsAt`,
/// entered at its member named after the current system when it has one:
/// that is how a flake lays out `checks` and `packages`.
pub fn rootsOf(ev: *Evaluator, a: Allocator, v_in: Value, args: *Attrs, attr: []const u8, roots: *std.ArrayList(DrvRoot)) Error!void {
    var v = try ev.force(try ev.autoCall(v_in, args));
    if (v.kind() != .attrs or v.as(Attrs).get(ev.s.drvPath) != null) return drvRoots(ev, a, v, roots);
    const tree = v.as(Attrs);
    const system = ev.config.system;
    var at = attr;
    if (tree.get(try ev.sym(system))) |m| {
        v = m.cell.get();
        at = try joinAttr(a, attr, system);
    }
    var found: std.ArrayList(Root) = .empty;
    var seen: Seen = .empty;
    defer seen.deinit(ev.gpa);
    try getDrvsAt(ev, a, v, args, &found, &seen, at);
    for (found.items) |r| try roots.append(a, .{ .drv = r.drv });
}

/// Derivation and output pairs a walk already reported.
pub const Seen = std.StringHashMapUnmanaged(void);

/// get-drvs.cc:getDerivations. A derivation is one root; an attrset is
/// walked in lexicographic name order and recursed into only with
/// `recurseForDerivations = true`; a list is always walked.
pub fn getDrvs(ev: *Evaluator, a: Allocator, v: Value, args: *Attrs, out: *std.ArrayList(Root), seen: *Seen) Error!void {
    return getDrvsAt(ev, a, v, args, out, seen, "");
}

/// `getDrvs`, telling every derivation it finds which attribute path it was
/// reached by (`attr` is the path already walked, from `-A`).
pub fn getDrvsAt(ev: *Evaluator, a: Allocator, v_in: Value, args: *Attrs, out: *std.ArrayList(Root), seen: *Seen, attr: []const u8) Error!void {
    const v = try ev.force(try ev.autoCall(v_in, args));
    if (try oneDerivation(ev, a, v, out, seen, attr)) return;
    switch (v.kind() orelse .int) {
        .attrs => {
            const attrs = v.as(Attrs);
            const Named = struct { name: []const u8, child: Value };
            const names = try a.alloc(Named, attrs.len);
            for (attrs.attrs(), names) |*at, *n| n.* = .{ .name = ev.interner.name(at.sym), .child = at.cell.get() };
            std.mem.sort(Named, names, {}, struct {
                fn lt(_: void, x: Named, y: Named) bool {
                    return std.mem.lessThan(u8, x.name, y.name);
                }
            }.lt);
            const recurse = try ev.sym("recurseForDerivations");
            for (names) |n| {
                if (!isAttrPathComponent(n.name)) continue;
                const sub = try joinAttr(a, attr, n.name);
                const child = try ev.force(n.child);
                if (try oneDerivation(ev, a, child, out, seen, sub)) continue;
                if (child.kind() != .attrs) continue;
                const r = child.as(Attrs).get(recurse) orelse continue;
                if (try ev.forceBool(r.cell.get(), r.pos, "while evaluating the attribute `recurseForDerivations`"))
                    try getDrvsAt(ev, a, child, args, out, seen, sub);
            }
        },
        .list => for (v.as(value.List).cells()) |*c| try getDrvsAt(ev, a, c.get(), args, out, seen, attr),
        else => return ev.fail(.type, .none, "expression does not evaluate to a derivation (or a set or list of those)", .{}),
    }
}

/// `a.b` from `a` and `b`; `b` alone when the prefix is empty.
fn joinAttr(a: Allocator, prefix: []const u8, name: []const u8) ![]const u8 {
    if (prefix.len == 0) return name;
    return std.fmt.allocPrint(a, "{s}.{s}", .{ prefix, name });
}

/// True when `v` was a derivation and is now in `out`, or was a duplicate.
fn oneDerivation(ev: *Evaluator, a: Allocator, v: Value, out: *std.ArrayList(Root), seen: *Seen, attr: []const u8) Error!bool {
    if (v.kind() != .attrs) return false;
    const attrs = v.as(Attrs);
    if (!try isDerivation(ev, attrs)) return false;
    const drv = try drvOf(ev, attrs);
    const output = try outputName(ev, attrs, &drv);
    if (output.len == 0) return ev.fail(.eval, .none, "derivation '{f}' lacks an 'outputName' attribute", .{&drv});
    try derivation.setAttr(ev, drv.baseName(), attr);
    const key = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ drv.baseName(), output });
    const g = try seen.getOrPut(ev.gpa, key);
    if (!g.found_existing) try out.append(a, .{ .drv = drv, .output = try a.dupe(u8, output) });
    return true;
}

/// get-drvs.cc:isAttrPathComponent: `[A-Za-z_][A-Za-z0-9-_+]*`.
fn isAttrPathComponent(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '+')) return false;
    return true;
}

/// The program a flake output names, and the derivation output that holds it.
pub const App = struct {
    drv: StorePath,
    output: []const u8,
    out_path: []const u8,
    /// `<out_path>/bin/<mainProgram>`.
    program: []const u8,
};

/// app.cc:InstallableValue::toApp for an output that must be a derivation:
/// the program is `outPath/bin/<mainProgram>`, and `mainProgram` is
/// `meta.mainProgram`, else `pname`, else `name` without its version
/// (names.cc:DrvName).
pub fn toApp(ev: *Evaluator, a: Allocator, v_in: Value, attr_path: []const u8) Error!App {
    const v = try ev.force(v_in);
    if (v.kind() != .attrs) return ev.fail(.missing_attr, .none, "attribute '{s}.type' missing", .{attr_path});
    const attrs = v.as(Attrs);
    if (attrs.get(ev.s.type) == null) return ev.fail(.missing_attr, .none, "attribute '{s}.type' missing", .{attr_path});
    if (!try isDerivation(ev, attrs)) return ev.fail(.eval, .none, "attribute '{s}' should have type 'derivation'", .{attr_path});
    const drv = try drvOf(ev, attrs);
    const output = try outputName(ev, attrs, &drv);
    const op = attrs.get(ev.s.outPath) orelse return ev.fail(.missing_attr, .none, "attribute '{s}.outPath' missing", .{attr_path});
    const out_path = try forcedString(ev, op.cell.get(), "while evaluating 'outPath'");
    const n = attrs.get(ev.s.name) orelse return ev.fail(.missing_attr, .none, "attribute '{s}.name' missing", .{attr_path});
    const name = try forcedString(ev, n.cell.get(), "while evaluating 'name'");
    const main = (try mainProgram(ev, attrs)) orelse drvPname(name);
    return .{ .drv = drv, .output = output, .out_path = out_path, .program = try std.fmt.allocPrint(a, "{s}/bin/{s}", .{ out_path, main }) };
}

fn drvPname(s: []const u8) []const u8 {
    const name, _ = strings.splitDrvName(s);
    return name;
}

/// `meta.mainProgram`, else `pname`; null when neither is there.
fn mainProgram(ev: *Evaluator, attrs: *Attrs) Error!?[]const u8 {
    if (attrs.get(ev.s.meta)) |m| {
        const meta = try ev.force(m.cell.get());
        if (meta.kind() == .attrs) if (meta.as(Attrs).get(try ev.sym("mainProgram"))) |mp|
            return try forcedString(ev, mp.cell.get(), "while evaluating 'meta.mainProgram'");
    }
    const p = attrs.get(try ev.sym("pname")) orelse return null;
    return try forcedString(ev, p.cell.get(), "while evaluating 'pname'");
}

/// One installable's derivation and the outputs it installs.
pub const Install = struct {
    drv: StorePath,
    outputs: []const []const u8,
};

/// The derivation a value names, with no output selection
/// (installables.cc:Installable::toDerivations, which ignores the outputs).
/// `what` names the installable in the error a non-derivation gets.
pub fn toDerivation(ev: *Evaluator, v_in: Value, what: []const u8) Error!StorePath {
    const v = try ev.force(v_in);
    if (v.kind() != .attrs or !try isDerivation(ev, v.as(Attrs)))
        return ev.fail(.unsupported, .none, "the installable '{s}' is not a derivation", .{what});
    return drvOf(ev, v.as(Attrs));
}

/// The derivation a value names and its outputs to install
/// (get-drvs.cc:queryOutputs, installable-flake.cc:toDerivedPaths):
/// `outputSpecified` picks one, else `meta.outputsToInstall`, else every
/// output for an attr-path installable and `out` for a flake one.
pub fn toInstall(ev: *Evaluator, a: Allocator, v_in: Value, what: []const u8, flake: bool) Error!Install {
    const v = try ev.force(v_in);
    if (v.kind() != .attrs or !try isDerivation(ev, v.as(Attrs)))
        return ev.fail(.unsupported, .none, "the installable '{s}' is not a derivation", .{what});
    const attrs = v.as(Attrs);
    const drv = try drvOf(ev, attrs);
    const specified = if (attrs.get(try ev.sym("outputSpecified"))) |s|
        try ev.forceBool(s.cell.get(), s.pos, "while evaluating the 'outputSpecified' attribute of a derivation")
    else
        false;
    if (specified) {
        const o = try a.alloc([]const u8, 1);
        o[0] = try outputName(ev, attrs, &drv);
        return .{ .drv = drv, .outputs = o };
    }
    if (attrs.get(ev.s.meta)) |m| {
        const meta = try ev.force(m.cell.get());
        if (meta.kind() == .attrs) if (meta.as(Attrs).get(try ev.sym("outputsToInstall"))) |oti| {
            const outs = try stringList(ev, a, oti.cell.get(), "this derivation has bad 'meta.outputsToInstall'", "while evaluating 'meta.outputsToInstall'");
            std.mem.sort([]const u8, @constCast(outs), {}, lessStr);
            return .{ .drv = drv, .outputs = outs };
        };
    }
    if (flake) return .{ .drv = drv, .outputs = &.{"out"} };
    var outs: []const []const u8 = if (attrs.get(ev.s.outputs)) |o|
        try stringList(ev, a, o.cell.get(), "the 'outputs' attribute of a derivation is not a list", "while evaluating the name of an output of a derivation")
    else
        &.{};
    if (outs.len == 0) outs = &.{"out"};
    const sorted = try a.dupe([]const u8, outs);
    std.mem.sort([]const u8, sorted, {}, lessStr);
    return .{ .drv = drv, .outputs = sorted };
}

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

const testing = std.testing;

test "the name a program takes from a derivation name" {
    try testing.expectEqualStrings("treefmt", drvPname("treefmt-2.0.0"));
    try testing.expectEqualStrings("nixfmt", drvPname("nixfmt"));
    // a dash before a letter is part of the name
    try testing.expectEqualStrings("nixfmt-tree", drvPname("nixfmt-tree"));
    try testing.expectEqualStrings("apache-httpd", drvPname("apache-httpd-2.0.48"));
    try testing.expectEqualStrings("fmt-e2e", drvPname("fmt-e2e-1.0"));
    try testing.expectEqualStrings("x-", drvPname("x-"));
}

fn expectPaths(want: []const []const u8, got: []const []const u8) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "default and fragment attr paths" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectPaths(&.{ "devShells.x86_64-linux.default", "devShell.x86_64-linux", "packages.x86_64-linux.default", "defaultPackage.x86_64-linux" }, try attrPaths(a, .dev_shell, "", "x86_64-linux"));
    try expectPaths(&.{ "devShells.x86_64-linux.ci", "packages.x86_64-linux.ci", "legacyPackages.x86_64-linux.ci", "ci" }, try attrPaths(a, .dev_shell, "ci", "x86_64-linux"));
    try expectPaths(&.{ "packages.s.default", "defaultPackage.s" }, try attrPaths(a, .package, "", "s"));
    try expectPaths(&.{ "packages.s.hello", "legacyPackages.s.hello", "hello" }, try attrPaths(a, .package, "hello", "s"));
    try expectPaths(&.{ "packages.s", "legacyPackages.s" }, try attrPaths(a, .package_set, "", "s"));
    try expectPaths(&.{ "packages.s.sub", "legacyPackages.s.sub", "sub" }, try attrPaths(a, .package_set, "sub", "s"));
    for ([_]Prefixes{ .package, .dev_shell, .package_set }) |p| try expectPaths(&.{"a.b"}, try attrPaths(a, p, ".a.b", "s"));
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try showAttrPaths(&buf.writer, &.{ "a", "b", "c" });
    try testing.expectEqualStrings("'a', 'b' or 'c'", buf.written());
}

test "attribute paths split at dots, quotes keep them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    try expectPaths(&.{ "a", "b.c", "d" }, try parseAttrPath(arena.allocator(), "a.\"b.c\".d", &d));
    try expectPaths(&.{ "a", "" }, try parseAttrPath(arena.allocator(), "a..", &d));
    try testing.expectError(error.Flake, parseAttrPath(arena.allocator(), "a.\"b", &d));
    try testing.expectEqualStrings("missing closing quote in selection path 'a.\"b'", d.message());
}

test "attr path components" {
    try testing.expect(isAttrPathComponent("a-b_c+1"));
    try testing.expect(isAttrPathComponent("_x"));
    try testing.expect(!isAttrPathComponent("1a"));
    try testing.expect(!isAttrPathComponent(""));
    try testing.expect(!isAttrPathComponent("a.b"));
}
