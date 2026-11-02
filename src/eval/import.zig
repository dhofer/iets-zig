//! Loading sources: `import`, `scopedImport`, `<name>` lookup, and the
//! expression given on the command line.

const std = @import("std");
const errors = @import("../errors.zig");
const Evaluator = @import("Evaluator.zig");
const Error = Evaluator.Error;
const value = @import("../runtime/value.zig");
const Value = value.Value;
const Pos = @import("../syntax/pos.zig").Pos;
const Sym = @import("../syntax/symbol.zig").Sym;
const Parser = @import("../syntax/parser.zig").Parser;
const Diag = @import("../diag.zig").Diag;
const compile = @import("../compile.zig");
const ir = @import("ir.zig");
const corepkgs = @import("../corepkgs.zig");
const store_hooks = @import("../builtins/store_hooks.zig");
const store_path = @import("../store/path.zig");
const ir_cache = @import("../ir_cache.zig");
const Files = @import("Files.zig");
const lint = @import("../lint.zig");
const lint_report = lint.report;

/// Where embedded sources live; a path under it is never on disk.
pub const corepkgs_prefix = "/__corepkgs__/";

pub fn dirOf(p: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, p, '/') orelse return ".";
    return if (i == 0) "/" else p[0..i];
}

/// Parse and compile `src`, registered as `path`. Relative path literals
/// resolve against `base_dir`; `extra` names a `scopedImport` scope.
pub fn compileSource(ev: *Evaluator, path: []const u8, src: []const u8, base_dir: []const u8, extra: ?[]const Sym) Error!ir.Ref {
    return compileAdded(ev, try ev.files.add(path, src), src, base_dir, extra, null, null);
}

/// An embedded source (corepkgs, the derivation wrappers) is never linted.
/// The entry expression is a text of its own, linted like a file.
fn isInternal(path: []const u8) bool {
    if (std.mem.startsWith(u8, path, corepkgs_prefix)) return true;
    if (!std.mem.startsWith(u8, path, "«")) return false;
    return !std.mem.eql(u8, path, "«string»") and !std.mem.eql(u8, path, "«arg»");
}

fn freeDiags(ev: *Evaluator, diags: *std.ArrayList(lint.Diag)) void {
    for (diags.items) |dg| ev.gpa.free(dg.msg);
    diags.deinit(ev.gpa);
}

/// Sources past this size get a parse tree of their own, freed after the
/// compile; the largest file most evaluations meet is under it.
const max_reused_source = 2 << 20;

/// `compileSource` for a file already registered: its lint warnings are
/// reported, and handed to `diags_out` too when given (for the IR cache).
fn compileAdded(ev: *Evaluator, file: *Files.File, src: []const u8, base_dir: []const u8, extra: ?[]const Sym, used_home: ?*bool, diags_out: ?*std.ArrayList(lint.Diag)) Error!ir.Ref {
    var own: std.ArrayList(lint.Diag) = .empty;
    defer freeDiags(ev, &own);
    const diags = diags_out orelse &own;
    // a `~/` literal reads `HOME`, which the read set must hold
    var home = false;
    const code = compileTree(ev, file, src, base_dir, extra, used_home orelse &home, diags);
    if ((used_home orelse &home).*) ev.trace().env("HOME");
    const c = try code;
    try lint_report.reportDiags(ev, diags.items);
    return c;
}

fn compileTree(ev: *Evaluator, file: *Files.File, src: []const u8, base_dir: []const u8, extra: ?[]const Sym, used_home: ?*bool, diags: *std.ArrayList(lint.Diag)) Error!ir.Ref {
    const t0 = std.Io.Timestamp.now(ev.io, .awake);
    defer ev.stats.compile_ns += @intCast(t0.durationTo(std.Io.Timestamp.now(ev.io, .awake)).nanoseconds);
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    // The tree's buffers carry over from file to file.
    var p = try Parser.init(ev.gpa, src, ev.interner, ev.local.ast_reuse, &d);
    ev.local.ast_reuse = .{};
    defer p.deinit();
    const par = ev.parallel();
    if (par) |*x| p.par = x;
    var tree = p.parseFile(@fromBackingInt(file.id)) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return ev.fail(.parse, .at(file.base + p.errorOffset()), "{s}", .{d.message()}),
    };
    // An outsized file's buffers would stay for the rest of the run:
    // hackage-packages.nix alone leaves some 60 MB.
    defer if (src.len <= max_reused_source) {
        ev.local.ast_reuse = tree;
    } else tree.deinit(ev.gpa);
    ev.stats.parse_ns += @intCast(t0.durationTo(std.Io.Timestamp.now(ev.io, .awake)).nanoseconds);
    ev.stats.files += 1;
    const before = ev.local.arena.used;
    const strings_before = ev.stats.bytes.get(.string) + ev.stats.bytes.get(.string_bytes) + ev.stats.bytes.get(.attrs) + ev.stats.bytes.get(.list);
    defer {
        // Literals the compile makes count as their own kinds already.
        const lits = ev.stats.bytes.get(.string) + ev.stats.bytes.get(.string_bytes) + ev.stats.bytes.get(.attrs) + ev.stats.bytes.get(.list) - strings_before;
        ev.stats.bytes.getPtr(.ir).* += ev.local.arena.used - before - lits;
        if (Evaluator.census.enabled) {
            const c = &ev.local.arena.census;
            c.ir_by_file.append(c.gpa, .{ file.id, ev.local.arena.used - before }) catch {};
        }
    }
    if (isInternal(file.path)) return compile.compile(ev, &tree, file.base, base_dir, ev.config.home, extra, used_home, null);
    const cfg = lint_report.configForFile(ev, file.path);
    return compile.compile(ev, &tree, file.base, base_dir, ev.config.home, extra, used_home, .{ .config = &cfg, .src = src, .allows = &file.allows, .diags = diags });
}

/// `compileSource` for an imported file, through the IR cache when it is
/// on. An entry is keyed on the source and the compile-time lint levels the
/// file gets after the scope rule, so a store file under `scope = "root"`
/// keys like an unlinted one. It carries the compile's lint warnings, which
/// a load reports again, and the file's `# iets: allow` table for the
/// runtime lints. A file with a `~/` literal bypasses it.
fn compileFile(ev: *Evaluator, path: []const u8, src: []const u8) Error!ir.Ref {
    const cache = ev.config.ir_cache orelse return compileSource(ev, path, src, dirOf(path), null);
    const c = ev.config;
    if (std.mem.startsWith(u8, path, corepkgs_prefix) or src.len < cache.min_size)
        return compileSource(ev, path, src, dirOf(path), null);
    const t0 = std.Io.Timestamp.now(ev.io, .awake);
    var kbuf: [lint.N]u8 = undefined;
    const lint_key = lint_report.configForFile(ev, path).compileKey(&kbuf);
    const k = ir_cache.IrCache.key(path, src, c.system, store_path.store_dir, lint_key, c.pure);
    const file = try ev.files.add(path, src);
    if (cache.read(&k)) |bytes| {
        defer cache.gpa.free(bytes);
        const before = ev.local.arena.used;
        const loaded = try ir_cache.deserialize(ev, ir_cache.IrCache.body(bytes), file.base, @intCast(src.len));
        ev.stats.bytes.getPtr(.ir).* += ev.local.arena.used - before;
        if (loaded) |l| {
            var entry = l;
            defer entry.deinit(ev.gpa);
            file.allows = entry.allows;
            entry.allows = .{};
            try lint_report.reportDiags(ev, entry.diags.items);
            if (cache.stats) |w| w.print("ir-cache load {s} {d} {d}us\n", .{ path, src.len, @divTrunc(t0.durationTo(std.Io.Timestamp.now(ev.io, .awake)).nanoseconds, 1000) }) catch {};
            return entry.code;
        }
        cache.discard(&k);
    }
    var used_home = false;
    var diags: std.ArrayList(lint.Diag) = .empty;
    defer freeDiags(ev, &diags);
    const code = try compileAdded(ev, file, src, dirOf(path), null, &used_home, &diags);
    if (!used_home) if (try ir_cache.serialize(ev, code, file.base, diags.items, &file.allows)) |bytes| {
        defer ev.gpa.free(bytes);
        cache.write(&k, bytes);
    };
    if (cache.stats) |w| w.print("ir-cache store {s} {d}us\n", .{ path, @divTrunc(t0.durationTo(std.Io.Timestamp.now(ev.io, .awake)).nanoseconds, 1000) }) catch {};
    return code;
}

/// `-E`: an expression from the command line, relative to the current directory.
pub fn evalString(ev: *Evaluator, src: []const u8) Error!Value {
    const code = try compileSource(ev, "«string»", src, ev.config.cwd, null);
    return ev.eval(ev.root_env, code);
}

/// `import`: parse, compile and evaluate a file once. Each file is one thunk
/// in the shared table, so whichever thread forces it first does the work
/// and the others wait for it or take its value.
pub fn evalFile(ev: *Evaluator, path: []const u8, pos: Pos) Error!Value {
    const resolved = try resolveImportPath(ev, path, pos);
    const thunk = blk: {
        const key = try ev.local.arena.dupe(u8, resolved);
        const node = try ev.local.arena.create(ir.Ir);
        node.* = .{ .import_file = key };
        const sh = ev.shared;
        sh.imports_lock.lockUncancelable(ev.io);
        defer sh.imports_lock.unlock(ev.io);
        const gop = try sh.imports.getOrPut(ev.gpa, key);
        if (!gop.found_existing) gop.value_ptr.* = try ev.mkThunk(ev.root_env, node);
        break :blk gop.value_ptr.*;
    };
    return ev.force(thunk);
}

/// What an import thunk runs: the file at the resolved `path`, evaluated.
pub noinline fn load(ev: *Evaluator, path: []const u8) Error!Value {
    const src = try readSource(ev, path, .none);
    const code = blk: {
        defer src.deinit(ev);
        break :blk try compileFile(ev, path, src.bytes);
    };
    return ev.eval(ev.root_env, code);
}

/// `scopedImport`: `scope`'s attributes bound around the file; never cached.
pub fn scopedImport(ev: *Evaluator, scope: *value.Attrs, path: []const u8, pos: Pos) Error!Value {
    const resolved = try resolveImportPath(ev, path, pos);
    const src = try readSource(ev, resolved, pos);
    defer src.deinit(ev);
    const attrs = scope.attrs();
    const names = try ev.local.arena.allocSlice(Sym, attrs.len);
    for (attrs, names) |a, *n| n.* = a.sym;
    const code = try compileSource(ev, resolved, src.bytes, dirOf(resolved), names);
    const env = try ev.allocEnv(ev.root_env, attrs.len);
    for (attrs, 0..) |a, i| env.slot(i).* = .init(a.cell.get());
    return ev.eval(env, code);
}

// A path under a store path this evaluation made
// reads the tree or text it stands for (`store_hooks.locate`), and a pure
// evaluation reads only what `store_hooks.allowed` admits.

fn resolveImportPath(ev: *Evaluator, path: []const u8, pos: Pos) Error![]const u8 {
    if (std.mem.startsWith(u8, path, corepkgs_prefix)) return path;
    var p = path;
    var at = try store_hooks.open(ev, p, pos);
    try lint.coerce.readThroughCopy(ev, p, pos);
    // eval.cc:resolveExprPath follows a symlink on the last component, so a
    // relative path in the file resolves against the directory of the
    // target. A path inside a copied tree keeps `store_hooks`' own resolution.
    if (try at.local(ev)) |local| if ((try store_hooks.locate(ev, p)) == null and isSymlink(ev, local)) {
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        for (0..1024) |_| {
            const n = std.Io.Dir.cwd().readLink(ev.io, p, &buf) catch break;
            const t = buf[0..n];
            const joined = if (std.mem.startsWith(u8, t, "/"))
                t
            else
                try std.mem.concat(ev.local.arena.allocator(), u8, &.{ dirOf(p), "/", t });
            p = try Evaluator.canonPath(ev.local.arena.allocator(), joined);
        }
        if (ev.trace().isOn()) {
            const full = std.Io.Dir.cwd().realPathFileAlloc(ev.io, local, ev.local.arena.allocator()) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
            ev.trace().canon(local, full);
        }
        at = try store_hooks.open(ev, p, pos);
    };
    const dir = at.isDir(ev) catch |e| switch (e) {
        error.OutOfMemory, error.EvalFailed => |x| return x,
        else => return ev.fail(.io, pos, "getting status of '{s}': {s}", .{ p, errors.ioText(e) }),
    };
    if (dir) return std.mem.concat(ev.local.arena.allocator(), u8, &.{ p, "/default.nix" });
    return p;
}

fn isSymlink(ev: *Evaluator, p: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(ev.io, p, .{ .follow_symlinks = false }) catch return false;
    return st.kind == .sym_link;
}

/// A source to compile; `owned` ones are the caller's to free once compiled:
/// nothing the compiler makes points into them, and 40 MB of sources would
/// otherwise stay in the arena for the whole run.
const Source = struct {
    bytes: []const u8,
    owned: bool,

    fn deinit(s: Source, ev: *Evaluator) void {
        if (s.owned) ev.gpa.free(s.bytes);
    }
};

fn readSource(ev: *Evaluator, path: []const u8, pos: Pos) Error!Source {
    if (std.mem.startsWith(u8, path, corepkgs_prefix)) {
        if (corepkgs.get(path[corepkgs_prefix.len..])) |src| return .{ .bytes = src, .owned = false };
    }
    var failed: store_hooks.Failed = undefined;
    const sp = try store_hooks.resolve(ev, path);
    // Sized: the exact length, where a read to the end doubles its buffer.
    return .{ .owned = true, .bytes = sp.read(ev, ev.gpa, true, &failed) catch |e| switch (e) {
        error.IoFailed => {
            var buf: [128]u8 = undefined;
            return ev.fail(.io, pos, "opening file '{s}': {s}", .{ path, errors.osText(&buf, failed.err) });
        },
        else => |x| return x,
    } };
}

/// `<name>` lookup, as search-path.cc:SearchPath::resolve.
pub fn findFile(ev: *Evaluator, entries: []const Evaluator.SearchPathEntry, name: []const u8, pos: Pos) Error![]const u8 {
    const scratch = ev.local.arena.allocator();
    for (entries) |e| {
        // search-path.cc:Prefix::suffixIfPotentialMatch: the whole prefix must
        // match, so a prefix may hold a slash.
        const n = e.prefix.len;
        const sep = n > 0 and n < name.len;
        if ((sep and name[n] != '/') or !std.mem.startsWith(u8, name, e.prefix)) continue;
        const suffix = name[if (sep) n + 1 else n..];
        _ = try store_hooks.open(ev, e.path, pos);
        const candidate = if (suffix.len == 0) e.path else try std.mem.concat(scratch, u8, &.{ e.path, "/", suffix });
        const cp = try Evaluator.canonPath(scratch, candidate);
        if (try store_hooks.stat(ev, cp, true) != .missing) return cp;
    }
    if (std.mem.startsWith(u8, name, "nix/")) if (corepkgs.get(name[4..]) != null)
        return std.mem.concat(scratch, u8, &.{ corepkgs_prefix, name[4..] });
    if (ev.config.pure)
        return ev.fail(.throw, pos, "cannot look up '<{s}>' in pure evaluation mode (use '--impure' to override)", .{name});
    return ev.fail(.throw, pos, "file '{s}' was not found in the Nix search path (add it using $NIX_PATH or -I)", .{name});
}
