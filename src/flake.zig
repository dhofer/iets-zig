//! Locked flakes: `PATH#attr.path` on the command line and
//! `builtins.getFlake`, evaluated through Nix 2.34.8's `call-flake.nix`
//! (embedded verbatim) with `fetchTree` for the locked inputs and the root
//! tree copied like Nix copies it. Only a complete `flake.lock` is accepted,
//! or none for a flake without inputs; nothing is locked or looked up in a
//! registry. See docs/reference/flakes.md.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Evaluator = @import("eval/Evaluator.zig");
const Error = Evaluator.Error;
const value = @import("runtime/value.zig");
const Value = value.Value;
const Pos = @import("syntax/pos.zig").Pos;
const Diag = @import("diag.zig").Diag;
const text = @import("syntax/text.zig");
const StorePath = @import("store/path.zig").StorePath;
const import_ = @import("eval/import.zig");
const hooks = @import("builtins/store_hooks.zig");
const fetch = @import("builtins/fetch.zig");
const source = @import("source.zig");
const SourceRef = source.SourceRef;
const lock_mod = source.lock;
const Declared = lock_mod.Declared;

pub const flakeref = @import("flake/flakeref.zig");

pub const call_flake = @embedFile("flake/call-flake.nix");
pub const lock_error = "flake.lock missing or incomplete, run nix flake lock";

/// What parsing a reference fails with: `Flake` an invalid reference,
/// `Unsupported` a reference Nix takes and iets does not. The message is in
/// the `Diag`.
pub const RefError = flakeref.Error;

pub const FlakeRef = struct {
    /// The directory holding `flake.nix` and `flake.lock`.
    dir: []const u8,
    /// Where its tree comes from (flakeref.cc: a directory inside a working
    /// tree is `git+file://`, everything else is `path:`).
    source: SourceRef,
    /// The attribute path after `#`, selected from the flake's outputs.
    attr: []const []const u8,
    /// `source` came from a probe for a working tree, not from an explicit
    /// `path:`, so the evaluation records what the probe saw.
    probed: bool,
    /// `--reference-lock-file PATH`, read in place of `dir/flake.lock`.
    lock: ?[]const u8 = null,

    pub fn eql(x: *const FlakeRef, y: *const FlakeRef) bool {
        if (!std.mem.eql(u8, x.dir, y.dir) or !x.source.eql(&y.source) or x.probed != y.probed) return false;
        if (x.attr.len != y.attr.len) return false;
        for (x.attr, y.attr) |p, q| if (!std.mem.eql(u8, p, q)) return false;
        if ((x.lock == null) != (y.lock == null)) return false;
        return x.lock == null or std.mem.eql(u8, x.lock.?, y.lock.?);
    }
};

fn isFile(io: Io, p: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, p, .{}) catch return false;
    return st.kind == .file;
}

fn isDir(io: Io, p: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, p, .{}) catch return false;
    return st.kind == .directory;
}

fn exists(io: Io, p: []const u8) bool {
    _ = Io.Dir.cwd().statFile(io, p, .{}) catch return false;
    return true;
}

/// A command-line input that names a flake rather than a `.nix` file: it
/// has a `#`, a `path:` prefix, or is a directory with `flake.nix` and no
/// `default.nix`.
pub fn isFlakeRef(io: Io, arg: []const u8) bool {
    if (std.mem.indexOfScalar(u8, arg, '#') != null or std.mem.startsWith(u8, arg, "path:")) return true;
    var b1: [std.fs.max_path_bytes]u8 = undefined;
    var b2: [std.fs.max_path_bytes]u8 = undefined;
    const f = std.fmt.bufPrint(&b1, "{s}/flake.nix", .{arg}) catch return false;
    const d = std.fmt.bufPrint(&b2, "{s}/default.nix", .{arg}) catch return false;
    return isFile(io, f) and !exists(io, d);
}

/// `PATH[#attr.path]`, parsed by `flakeref.parse` with `cwd` as the base
/// directory. Only a local path is taken: `.`, `./x`, `/abs`, `~/x` or
/// `path:…`, or a checkout an SCM names (`git+file:///path?rev=…`).
pub fn parseFlakeRef(a: Allocator, io: Io, arg: []const u8, cwd: []const u8, home: ?[]const u8, d: *Diag) RefError!FlakeRef {
    const p = try flakeref.parse(a, arg, d);
    const loc = arg[0 .. std.mem.indexOfScalar(u8, arg, '#') orelse arg.len];
    const ty = source.strAttr(&p.input, "type");
    // A checkout an SCM names: CI pins the tree it evaluates as
    // `git+file:///path?ref=HEAD&rev=SHA`, which this process reads out of
    // the repository beside it (docs/reference/flakes.md).
    if (!p.bare) if (ty) |t| if (source.scm.named(t)) |s| return scmFlake(a, io, &p, s, loc, try parseAttrPath(a, p.fragment, d), d);
    if (ty == null or !std.mem.eql(u8, ty.?, "path")) {
        if (ty != null and std.mem.eql(u8, ty.?, "indirect"))
            return d.fail(error.Unsupported, "flake registry references ({s}#…) are not supported; use a path or a locked input", .{loc});
        return d.fail(error.Unsupported, "flake reference '{s}' is a '{s}' input; only local paths are supported (iets cannot fetch a root flake)", .{ loc, ty orelse "" });
    }
    if (p.input.len() > 2 or p.dir.len > 0)
        return d.fail(error.Unsupported, "query parameters in flake reference '{s}' are not supported", .{arg});
    const path = source.strAttr(&p.input, "path") orelse "";
    const full = blk: {
        if (p.bare and std.mem.startsWith(u8, path, "~")) {
            const rest = path[1..];
            if (rest.len == 0 or rest[0] == '/') {
                const h = home orelse return d.fail(error.Flake, "iets: $HOME is not set", .{});
                break :blk try std.mem.concat(a, u8, &.{ h, rest });
            }
        }
        if (std.mem.startsWith(u8, path, "/")) break :blk path;
        break :blk try std.mem.concat(a, u8, &.{ cwd, "/", path });
    };
    return localFlake(a, io, full, !p.bare, try parseAttrPath(a, p.fragment, d), d);
}

/// `git+file:///path[?ref=…&rev=…][&dir=…]`: the flake in `dir` of that
/// tree. With a `rev` the source is that revision, read out of the
/// repository; without one it is the working tree, as Nix reads it. A `ref`
/// beside a `rev` is advisory, as it is for Nix: the rev names the tree.
/// The `flake.lock` is the checked-out one either way
/// (docs/reference/divergences.md).
fn scmFlake(a: Allocator, io: Io, p: *const flakeref.Parsed, s: *const source.Scm, loc: []const u8, attr: []const []const u8, d: *Diag) RefError!FlakeRef {
    const known = [_][]const u8{ "type", "url", "ref", "rev" };
    for (p.input.items()) |e| {
        var ok = false;
        for (known) |k| ok = ok or std.mem.eql(u8, k, e.key);
        if (!ok) return d.fail(error.Unsupported, "'{s}' in flake reference '{s}' is not supported", .{ e.key, loc });
    }
    const url = source.strAttr(&p.input, "url") orelse "";
    const root = blk: {
        const r = (try flakeref.fileUrlPath(a, url)) orelse break :blk null;
        break :blk if (std.mem.startsWith(u8, r, "/")) r else null;
    } orelse return d.fail(error.Unsupported, "flake reference '{s}' is a '{s}' input; only local paths are supported (iets cannot fetch a root flake)", .{ loc, s.name });
    const dir = if (p.dir.len > 0) try source.scm.join(a, root, p.dir) else root;
    var fr = try localFlake(a, io, dir, false, attr, d);
    const rev = source.strAttr(&p.input, "rev") orelse {
        if (p.input.contains("ref"))
            return d.fail(error.Unsupported, "flake reference '{s}' names a '{s}' but no 'rev'; iets resolves no reference of a root flake, so name the rev or the directory", .{ loc, s.name });
        return fr;
    };
    if (!flakeref.isRev(rev))
        return d.fail(error.Flake, "flake reference '{s}': 'rev={s}' is not a revision; name the 40 hex digits of a commit", .{ loc, rev });
    fr.source = .{ .commit = .{ .scm = s, .root = try Evaluator.canonPath(a, root), .rev = rev, .subdir = p.dir } };
    fr.probed = false;
    return fr;
}

/// The flake in directory `full`: a `path:` input, or unless
/// `explicit_path` the input of the working tree holding it (`git+file:`).
fn localFlake(a: Allocator, io: Io, full_in: []const u8, explicit_path: bool, attr: []const []const u8, d: *Diag) RefError!FlakeRef {
    const dir = try Evaluator.canonPath(a, full_in);
    if (!isDir(io, dir)) return d.fail(error.Flake, "path '{s}' is not a flake (because it's not a directory)", .{dir});
    const f = try std.fmt.allocPrint(a, "{s}/flake.nix", .{if (std.mem.eql(u8, dir, "/")) "" else dir});
    if (!isFile(io, f)) return d.fail(error.Flake, "path '{s}' is not a flake (because it doesn't contain a 'flake.nix' file)", .{dir});
    const src: SourceRef = if (explicit_path) .{ .path = dir } else blk: {
        // git.cc opens the repository, which resolves the directory: a link
        // to a working tree is that tree, not a copy of the link object
        const real = Io.Dir.cwd().realPathFileAlloc(io, dir, a) catch dir;
        const found = source.scm.detect(io, real) orelse break :blk .{ .path = dir };
        const sub = if (real.len > found.root.len) std.mem.trimStart(u8, real[found.root.len..], "/") else "";
        break :blk .{ .tracked = .{ .scm = found.scm, .root = found.root, .subdir = sub } };
    };
    return .{ .dir = dir, .source = src, .attr = attr, .probed = !explicit_path };
}

/// attr-path.cc:parseAttrPath: `.` separates, `"..."` quotes.
pub fn parseAttrPath(a: Allocator, s: []const u8, d: *Diag) RefError![]const []const u8 {
    var res: std.ArrayList([]const u8) = .empty;
    var cur: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        switch (c) {
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
            else => try cur.append(a, c),
        }
    }
    if (cur.items.len > 0) try res.append(a, try cur.toOwnedSlice(a));
    return res.items;
}

/// A file read whole, recorded for the tracing cache.
fn readTraced(ev: *Evaluator, p: []const u8) ![]u8 {
    const meta = try @import("sys/fs.zig").stat(p, true);
    const bytes = try Io.Dir.cwd().readFileAlloc(ev.io, p, ev.local.arena.allocator(), .unlimited);
    ev.trace().file(p, meta, bytes);
    return bytes;
}

/// An error outside the evaluator as an evaluation error at `pos`; an
/// unsupported reference keeps its kind.
pub fn evalError(ev: *Evaluator, e: RefError, d: *const Diag, pos: Pos) Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Unsupported => ev.fail(.unsupported, pos, "{s}", .{d.message()}),
        error.Flake => ev.fail(.eval, pos, "{s}", .{d.message()}),
    };
}

/// Evaluates the top-level flake: the `callFlake` result (`_type`,
/// `inputs`, `outputs`, `sourceInfo` and its fields), as `nix-eval-jobs
/// --flake DIR` walks it.
pub fn evalFlakeValue(ev: *Evaluator, fr: *const FlakeRef) Error!Value {
    return loadFlake(ev, fr, true);
}

/// `top`: the flake a command names, whose `nixConfig` Nix would apply;
/// `builtins.getFlake` loads one that is not.
fn loadFlake(ev: *Evaluator, fr: *const FlakeRef, top: bool) Error!Value {
    const pos: Pos = .none;
    const a = ev.local.arena.allocator();
    const lock_path = fr.lock orelse try source.scm.join(a, fr.dir, "flake.lock");
    const lock_bytes: []const u8 = readTraced(ev, lock_path) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        // flake.cc locks a flake without inputs to an empty lock and writes
        // no file; one that declares inputs fails checkDeclaredInputs
        error.FileNotFound => if (fr.lock == null) blk: {
            _ = ev.trace().statNow(lock_path, true);
            break :blk lock_mod.empty;
        } else return ev.fail(.unsupported, pos, "cannot read the lock file '{s}'", .{lock_path}),
        else => if (fr.lock) |p|
            return ev.fail(.unsupported, pos, "cannot read the lock file '{s}'", .{p})
        else
            return ev.fail(.unsupported, pos, "{s}", .{lock_error}),
    };
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    const lock = lock_mod.check(a, lock_bytes, &d) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Flake => {
            const err = ev.fail(.unsupported, pos, "{s} ({s})", .{ lock_error, d.message() });
            if (d.hint) |h| if (ev.failure) |*f| {
                f.hint = try ev.gpa.dupe(u8, h);
            };
            return err;
        },
    };
    for (try lock.narHashNames(a)) |n| try source.remote.nameInput(ev, n.nar_hash, n.name);

    if (fr.probed) {
        const found: ?[]const u8 = switch (fr.source) {
            .tracked => |t| t.root,
            else => null,
        };
        source.scm.recordDetect(ev.trace(), fr.dir, found);
    }
    const root = try source.tree(ev, &fr.source, pos);
    const source_info = try fetch.emitTreeAttrs(ev, &root, "self", pos);
    const subdir = root.subdir;
    const out_path = blk: {
        const ctx = try std.fmt.allocPrint(a, "while evaluating the sourceInfo of flake '{s}'", .{fr.dir});
        const at = try ev.forceAttrs(source_info, pos, ctx);
        const attr = at.get(ev.s.outPath) orelse return ev.fail(.missing_attr, pos, "flake '{s}': sourceInfo has no attribute 'outPath'", .{fr.dir});
        break :blk (try ev.forceString(try ev.forceCell(&attr.cell), pos, "while evaluating the flake's outPath")).bytes();
    };
    if (StorePath.parse(out_path, &d)) |sp| try hooks.nameFlake(ev, &sp, lock.root) else |_| {}
    const flake_dir = if (subdir.len == 0) out_path else try std.fmt.allocPrint(a, "{s}/{s}", .{ out_path, subdir });
    const has_nix_config = try checkDeclaredInputs(ev, flake_dir, &lock, pos);
    if (top and has_nix_config) if (ev.config.session) |s| s.ignored.nixConfigSeen();

    const code = try import_.compileSource(ev, "«call-flake»", call_flake, "/", null);
    const call = try ev.eval(ev.root_env, code);
    const lock_str = try ev.mkString(lock_bytes);
    const dir_w = try ev.mkString(subdir);
    var ov = [_]value.Attr{
        .{ .sym = try ev.sym("sourceInfo"), .pos = pos, .cell = .init(source_info) },
        .{ .sym = try ev.sym("dir"), .pos = pos, .cell = .init(dir_w) },
    };
    const ov_v = try ev.mkAttrs(&ov, pos);
    var overrides = [_]value.Attr{.{ .sym = try ev.sym(lock.root), .pos = pos, .cell = .init(ov_v) }};
    const overrides_v = try ev.mkAttrs(&overrides, pos);
    // its own primop, not the one in `builtins`: `call-flake.nix` needs it
    // whatever `builtins` holds
    const fetch_tree = try ev.mkPrimOp("fetchTree", 1, fetch.fetchTree);
    return ev.apply(call, &.{ lock_str, overrides_v, fetch_tree }, pos);
}

/// flake-primops.cc:prim_getFlake on a local path, parsed by
/// `flakeref.parseAbsolute`. Impure, or pure on a `path:` reference with a
/// `narHash` the tree matches; a pure evaluation refuses every other one.
/// Nothing is locked here. A directory is always a `path:` input, even
/// inside a git repository: flakeref.cc looks for `.git` only when it has a
/// base directory, and getFlake passes none. A virtual copy stands for its
/// local tree.
pub fn getFlake(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const a = ev.local.arena.allocator();
    const raw = try ev.forceStringNoCtx(args[0], pos, "while evaluating the argument passed to builtins.getFlake");
    const s = if (std.unicode.utf8ValidateSlice(raw)) raw else try std.fmt.allocPrint(a, "{f}", .{text.lossy(raw)});
    var d: Diag = .init(a);
    const p = flakeref.parseAbsolute(a, s, &d) catch |e| return evalError(ev, e, &d, pos);
    const pinned = pinnedPath(&p);
    if (pinned) |pin| {
        var hd: Diag = .init(ev.gpa);
        defer hd.deinit();
        const expected = source.parseNarHash(pin.nar_hash, &hd) catch return ev.fail(.eval, pos, "{s}", .{hd.message()});
        switch (try fetch.pathNarHash(ev, pin.path, expected, pos)) {
            .found => {},
            .mismatch => |got| {
                var eb: [@import("store/hash.zig").Hash.max_string_len]u8 = undefined;
                var gb: [@import("store/hash.zig").Hash.max_string_len]u8 = undefined;
                return ev.fail(.eval, pos, "NAR hash mismatch in input '{s}', expected '{s}' but got '{s}'", .{ s, expected.print(&eb, .sri, true), got.print(&gb, .sri, true) });
            },
        }
    } else if (ev.config.pure) {
        // a rev may lock it; the real nix decides that
        if (p.input.contains("rev") or p.input.contains("narHash"))
            return ev.fail(.unsupported, pos, "builtins.getFlake on '{s}' in pure evaluation mode is not supported", .{s});
        // flake-primops.cc prints the primop's position, which it never has
        return ev.fail(.eval, pos, "cannot call 'getFlake' on unlocked flake reference '{s}', at «none»:0 (use --impure to override)", .{s});
    }
    const local = (p.input.len() == 2 or pinned != null) and p.dir.len == 0;
    const path = (if (local) source.strAttr(&p.input, "path") else null) orelse
        return ev.fail(.unsupported, pos, "builtins.getFlake on '{s}' (only a local path) is not supported", .{s});
    const full: []const u8 = blk: {
        const at = (try hooks.locate(ev, path)) orelse break :blk path;
        if (try at.hidden(ev)) break :blk path;
        break :blk (try at.local(ev)) orelse
            return ev.fail(.unsupported, pos, "builtins.getFlake on '{s}' (a fetched input) is not supported", .{s});
    };
    const fr = localFlake(a, ev.io, full, true, &.{}, &d) catch |e| return evalError(ev, e, &d, pos);
    return loadFlake(ev, &fr, false);
}

const Pinned = struct { path: []const u8, nar_hash: []const u8 };

/// `path:DIR?narHash=H` and nothing else: a reference its NAR hash locks,
/// so a pure evaluation may take it once the tree matches.
fn pinnedPath(p: *const flakeref.Parsed) ?Pinned {
    if (p.input.len() != 3 or p.dir.len != 0) return null;
    return .{ .path = source.strAttr(&p.input, "path") orelse return null, .nar_hash = source.strAttr(&p.input, "narHash") orelse return null };
}

/// Evaluates the flake and selects `attr` from its outputs (or returns the
/// outputs attrset for an empty path).
pub fn evalFlake(ev: *Evaluator, fr: *const FlakeRef) Error!Value {
    const result = try evalFlakeValue(ev, fr);
    return selectOutput(ev, fr, result);
}

/// `fr.attr` of the outputs in `result`, the value `evalFlakeValue` gave.
pub fn selectOutput(ev: *Evaluator, fr: *const FlakeRef, result: Value) Error!Value {
    const pos: Pos = .none;
    const a = ev.local.arena.allocator();
    const attrs = try ev.forceAttrs(result, pos, "while evaluating the flake");
    const outputs = attrs.get(try ev.sym("outputs")) orelse
        return ev.fail(.missing_attr, pos, "flake '{s}' has no attribute 'outputs'", .{fr.dir});
    const out_v = outputs.cell.get();
    const cands = try outputCandidates(a, fr.attr, ev.config.system);
    for (cands) |path| if (try select(ev, out_v, path)) |v| return ev.force(v);
    var shown: std.ArrayList(u8) = .empty;
    for (cands, 0..) |c, i| {
        if (i > 0) try shown.appendSlice(a, if (i + 1 == cands.len) " or " else ", ");
        try shown.append(a, '\'');
        for (c, 0..) |x, j| {
            if (j > 0) try shown.append(a, '.');
            try shown.appendSlice(a, x);
        }
        try shown.append(a, '\'');
    }
    return ev.fail(.missing_attr, pos, "flake '{s}' does not provide attribute {s}", .{ fr.dir, shown.items });
}

/// installable-flake.cc:getActualAttrPaths: `packages.<system>.`, then
/// `legacyPackages.<system>.`, then the path itself; a leading `.` names
/// the path from the root only. The empty path is the outputs.
fn outputCandidates(a: Allocator, attr: []const []const u8, system: []const u8) Allocator.Error![]const []const []const u8 {
    if (attr.len == 0) return try a.dupe([]const []const u8, &.{&.{}});
    if (attr[0].len == 0) return try a.dupe([]const []const u8, &.{attr[1..]});
    var out: std.ArrayList([]const []const u8) = .empty;
    for ([_][]const u8{ "packages", "legacyPackages" }) |set| {
        const p = try a.alloc([]const u8, attr.len + 2);
        p[0] = set;
        p[1] = system;
        @memcpy(p[2..], attr);
        try out.append(a, p);
    }
    try out.append(a, attr);
    return out.items;
}

/// eval-cache.cc:AttrCursor::findAlongAttrPath: walks `path` from `v`,
/// forcing each step; null when a step is missing or the value at a step is
/// not an attrset.
pub fn select(ev: *Evaluator, v_in: Value, path: []const []const u8) Error!?Value {
    var v = v_in;
    for (path) |name| {
        const forced = try ev.force(v);
        if (forced.kind() != .attrs) return null;
        const at = try ev.forceAttrs(forced, .none, "");
        const a = at.get(try ev.sym(name)) orelse return null;
        v = a.cell.get();
    }
    return v;
}

/// Every input `flake.nix` declares must have a lock entry; Nix would
/// otherwise fetch and lock it. flake.cc:getFlake declares one for each
/// name in `inputs`, and one for each formal of `outputs` but `self`. True
/// when `flake.nix` has a `nixConfig`.
fn checkDeclaredInputs(ev: *Evaluator, flake_dir: []const u8, lock: *const lock_mod.Lock, pos: Pos) Error!bool {
    const a = ev.local.arena.allocator();
    const v = try import_.evalFile(ev, try std.fmt.allocPrint(a, "{s}/flake.nix", .{flake_dir}), pos);
    const attrs = try ev.forceAttrs(v, pos, "while evaluating flake.nix");
    const Decl = struct { sym: @import("syntax/symbol.zig").Sym, how: []const u8 };
    var declared: std.ArrayList(Decl) = .empty;
    var inputs: ?*value.Attrs = null;
    if (attrs.get(try ev.sym("inputs"))) |in| {
        const ia = try ev.forceAttrs(try ev.forceCell(&in.cell), pos, "while evaluating the 'inputs' attribute of flake.nix");
        for (ia.attrs()) |x| try declared.append(a, .{ .sym = x.sym, .how = "" });
        inputs = ia;
    }
    if (attrs.get(ev.s.outputs)) |o| {
        const outputs = try ev.forceCell(&o.cell);
        if (outputs.view() == .lambda) {
            const l = outputs.view().lambda;
            switch (l.lam.param) {
                .formals => |f| {
                    const self_sym = try ev.sym("self");
                    for (f.formals) |x| if (x.sym != self_sym)
                        try declared.append(a, .{ .sym = x.sym, .how = ", an argument of 'outputs' that Nix looks up in the flake registry," });
                },
                .ident => {},
            }
        }
    }
    for (declared.items) |x| {
        const name = ev.interner.name(x.sym);
        if (!lock.hasRootInput(name))
            return ev.fail(.unsupported, pos, "{s} (input '{f}'{s} has no lock entry)", .{ lock_error, text.lossy(name), x.how });
    }
    if (inputs) |in| try checkInputs(ev, lock, lock.root, "", in, pos);
    return attrs.get(try ev.sym("nixConfig")) != null;
}

/// flake.cc:computeLocks keeps a lock entry only while `flake.nix`, with
/// the overrides in it, still asks for it. Only the root's `flake.nix` is
/// read, so a stale `follows` that an input's own flake declares passes.
fn checkInputs(ev: *Evaluator, lock: *const lock_mod.Lock, node: []const u8, path: []const u8, inputs: *value.Attrs, pos: Pos) Error!void {
    const a = ev.local.arena.allocator();
    for (inputs.attrs()) |*x| {
        const name = try std.fmt.allocPrint(a, "{f}", .{text.lossy(ev.interner.name(x.sym))});
        const at = if (path.len == 0) name else try std.fmt.allocPrint(a, "{s}/{s}", .{ path, name });
        const decl = try ev.forceAttrs(try ev.forceCell(&x.cell), pos, "while evaluating a flake input");
        const url = decl.get(try ev.sym("url"));
        const follows = decl.get(try ev.sym("follows"));
        const sub = decl.get(try ev.sym("inputs"));
        const is_ref = url != null or decl.get(ev.s.type) != null;
        const want: Declared = blk: {
            if (follows) |f| {
                if (is_ref) return ev.fail(.eval, pos, "flake input '{s}' has both a flake reference and a follows attribute", .{at});
                const fs = try ev.forceStringNoCtx(try ev.forceCell(&f.cell), pos, "while evaluating a follows attribute");
                var parts: std.ArrayList([]const u8) = .empty;
                var it = std.mem.splitScalar(u8, try std.fmt.allocPrint(a, "{f}", .{text.lossy(fs)}), '/');
                while (it.next()) |s| if (s.len > 0) try parts.append(a, s);
                break :blk .{ .follows = parts.items };
            }
            if (url) |u| break :blk try declaredRef(ev, try ev.forceCell(&u.cell));
            break :blk .unknown;
        };
        if (try lock.disagrees(a, node, name, &want)) |why|
            return ev.fail(.unsupported, pos, "{s} (input '{s}' {s}, not in flake.lock)", .{ lock_error, at, why });
        if (sub) |s| if (lock.child(node, name)) |child| {
            const sa = try ev.forceAttrs(try ev.forceCell(&s.cell), pos, "while evaluating the 'inputs' of a flake input");
            try checkInputs(ev, lock, child, at, sa, pos);
        };
    }
}

/// A url string as the lock's `original` holds it; a path value or a url
/// iets cannot parse is not compared.
fn declaredRef(ev: *Evaluator, url_v: Value) Error!Declared {
    const a = ev.local.arena.allocator();
    const v = try ev.force(url_v);
    if (v.kind() != .string) return .unknown;
    const url = try std.fmt.allocPrint(a, "{f}", .{text.lossy(v.as(value.String).bytes())});
    var d: Diag = .init(a);
    var p = flakeref.parse(a, url, &d) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .unknown,
    };
    if (p.dir.len > 0) try p.input.put(a, "dir", .{ .str = p.dir });
    var original: std.json.ObjectMap = .empty;
    for (p.input.items()) |e| try original.put(a, e.key, switch (e.value) {
        .str => |s| .{ .string = s },
        .bool => |b| .{ .bool = b },
        .int => |n| .{ .integer = @intCast(n) },
    });
    return .{ .ref = .{ .url = url, .original = original } };
}

const testing = std.testing;

test "attr paths" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .init(a);
    const one = try parseAttrPath(a, "devShells.x86_64-linux.default.drvPath", &d);
    try testing.expectEqual(@as(usize, 4), one.len);
    try testing.expectEqualStrings("drvPath", one[3]);
    const two = try parseAttrPath(a, "packages.\"x86_64-linux\".\"a.b\"", &d);
    try testing.expectEqual(@as(usize, 3), two.len);
    try testing.expectEqualStrings("x86_64-linux", two[1]);
    try testing.expectEqualStrings("a.b", two[2]);
    try testing.expectEqual(@as(usize, 0), (try parseAttrPath(a, "", &d)).len);
    try testing.expectError(error.Flake, parseAttrPath(a, "a.\"b", &d));
}

/// A scratch directory under /tmp: the repository the tests run in is a git
/// working tree, which detection would find above the test's directory.
const Tmp = struct {
    root: []u8,

    fn init() !Tmp {
        var r: [8]u8 = undefined;
        @import("sys.zig").random(&r);
        const root = try std.fmt.allocPrint(testing.allocator, "/tmp/iets-flake-{x}", .{r});
        try Io.Dir.cwd().createDirPath(testing.io, root);
        return .{ .root = root };
    }

    fn deinit(t: *Tmp) void {
        Io.Dir.cwd().deleteTree(testing.io, t.root) catch {};
        testing.allocator.free(t.root);
    }

    fn write(t: *Tmp, rel: []const u8, data: []const u8) !void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const p = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ t.root, rel });
        if (std.fs.path.dirname(p)) |dir| try Io.Dir.cwd().createDirPath(testing.io, dir);
        try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = p, .data = data });
    }

    fn mkdir(t: *Tmp, rel: []const u8) !void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        try Io.Dir.cwd().createDirPath(testing.io, try std.fmt.bufPrint(&buf, "{s}/{s}", .{ t.root, rel }));
    }
};

test "refs resolve against cwd and home" {
    var t: Tmp = try .init();
    defer t.deinit();
    try t.write("flake.nix", "{ outputs = _: {}; }");
    try t.write("sub/flake.nix", "{ outputs = _: {}; }");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .init(a);
    const io = testing.io;
    const sub = try std.fmt.allocPrint(a, "{s}/sub", .{t.root});
    var r = try parseFlakeRef(a, io, ".#a.b", t.root, null, &d);
    try testing.expectEqualStrings(t.root, r.dir);
    try testing.expect(r.source.eql(&.{ .path = t.root }));
    try testing.expectEqual(@as(usize, 2), r.attr.len);
    r = try parseFlakeRef(a, io, "./sub", t.root, null, &d);
    try testing.expectEqualStrings(sub, r.dir);
    try testing.expectEqual(@as(usize, 0), r.attr.len);
    r = try parseFlakeRef(a, io, "~/sub#", "/", t.root, &d);
    try testing.expectEqualStrings(sub, r.dir);
    try testing.expectError(error.Flake, parseFlakeRef(a, io, "./missing", t.root, null, &d));
    for ([_][]const u8{ "github:a/b#x", "git+https://x.org/a", "https://x.org/a.tar.gz#x" }) |x| {
        try testing.expectError(error.Unsupported, parseFlakeRef(a, io, x, t.root, null, &d));
        try testing.expect(std.mem.indexOf(u8, d.message(), "only local paths") != null);
    }
    try testing.expectError(error.Unsupported, parseFlakeRef(a, io, ".?dir=sub", t.root, null, &d));
    try testing.expect(std.mem.indexOf(u8, d.message(), "query parameters") != null);
    try testing.expectError(error.Unsupported, parseFlakeRef(a, io, "hg+https://x.org/a#x", t.root, null, &d));
    try testing.expect(std.mem.indexOf(u8, d.message(), "not supported") != null);
    try testing.expectError(error.Flake, parseFlakeRef(a, io, "./x#%zz", t.root, null, &d));
    try testing.expectEqualStrings(sub, (try parseFlakeRef(a, io, "path:./sub", t.root, null, &d)).dir);
    for ([_][]const u8{ "nixpkgs#hello", "nixpkgs/nixos-24.05#x", "flake:nixpkgs", "sub#x" }) |x| {
        try testing.expectError(error.Unsupported, parseFlakeRef(a, io, x, t.root, null, &d));
        try testing.expect(std.mem.indexOf(u8, d.message(), "flake registry references") != null);
    }
    try testing.expect(isFlakeRef(io, sub));
    try testing.expect(!isFlakeRef(io, "x.nix"));
}

test "a pinned checkout is its revision" {
    var t: Tmp = try .init();
    defer t.deinit();
    try t.write("flake.nix", "{ outputs = _: {}; }");
    try t.write("sub/flake.nix", "{ outputs = _: {}; }");
    try t.mkdir(".git");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .init(a);
    const io = testing.io;
    const rev = @as([39]u8, @splat('0')) ++ "1";
    const git = source.scm.named("git").?;
    const url = try std.fmt.allocPrint(a, "git+file://{s}", .{t.root});
    var r = try parseFlakeRef(a, io, try std.fmt.allocPrint(a, "{s}?ref=HEAD&rev={s}#a", .{ url, rev }), "/", null, &d);
    try testing.expectEqualStrings(t.root, r.dir);
    try testing.expect(r.source.eql(&.{ .commit = .{ .scm = git, .root = t.root, .rev = rev, .subdir = "" } }));
    // `dir` is the flake inside the tree, and the tree stays the root
    r = try parseFlakeRef(a, io, try std.fmt.allocPrint(a, "{s}?rev={s}&dir=sub", .{ url, rev }), "/", null, &d);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/sub", .{t.root}), r.dir);
    try testing.expect(r.source.eql(&.{ .commit = .{ .scm = git, .root = t.root, .rev = rev, .subdir = "sub" } }));
    // no rev: the working tree, as a plain path resolves to
    r = try parseFlakeRef(a, io, url, "/", null, &d);
    try testing.expect(r.source.eql(&.{ .tracked = .{ .scm = git, .root = t.root, .subdir = "" } }));
    try testing.expectError(error.Unsupported, parseFlakeRef(a, io, try std.fmt.allocPrint(a, "{s}?ref=main", .{url}), "/", null, &d));
    try testing.expect(std.mem.indexOf(u8, d.message(), "no 'rev'") != null);
    try testing.expectError(error.Unsupported, parseFlakeRef(a, io, try std.fmt.allocPrint(a, "{s}?submodules=1", .{url}), "/", null, &d));
    try testing.expect(std.mem.indexOf(u8, d.message(), "'submodules'") != null);
    try testing.expectError(error.Unsupported, parseFlakeRef(a, io, "git+https://x.org/a", "/", null, &d));
    // a rev that is not one says so, instead of the repository reporting
    // that it has no revision ''
    for ([_][]const u8{ "", "HEAD", "0123", &@as([40]u8, @splat('z')) }) |x| {
        try testing.expectError(error.Flake, parseFlakeRef(a, io, try std.fmt.allocPrint(a, "{s}?rev={s}", .{ url, x }), "/", null, &d));
        try testing.expect(std.mem.indexOf(u8, d.message(), "is not a revision") != null);
    }
}

test "a directory in a repository is found" {
    var t: Tmp = try .init();
    defer t.deinit();
    try t.write("sub/flake.nix", "{ outputs = _: {}; }");
    try t.mkdir(".git");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .init(a);
    const r = try parseFlakeRef(a, testing.io, try std.fmt.allocPrint(a, "{s}/sub#x", .{t.root}), "/", null, &d);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "git+file://{s}?dir=sub", .{t.root}), try refUrl(a, &r));
    const p = try parseFlakeRef(a, testing.io, try std.fmt.allocPrint(a, "path:{s}/sub", .{t.root}), "/", null, &d);
    try testing.expect(p.source.eql(&.{ .path = try std.fmt.allocPrint(a, "{s}/sub", .{t.root}) }));
}

/// flakeref.cc:FlakeRef::to_string for the references iets parses: how a
/// local flake names itself in a message.
pub fn refUrl(a: Allocator, fr: *const FlakeRef) Allocator.Error![]const u8 {
    return switch (fr.source) {
        .tracked => |t| if (t.subdir.len == 0)
            std.fmt.allocPrint(a, "{s}+file://{s}", .{ t.scm.name, t.root })
        else
            std.fmt.allocPrint(a, "{s}+file://{s}?dir={s}", .{ t.scm.name, t.root, t.subdir }),
        else => std.fmt.allocPrint(a, "path:{s}", .{fr.dir}),
    };
}
