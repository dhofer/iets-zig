//! AST to IR: scope resolution, attrpath merging, `inherit` expansion, literal
//! allocation, and folding of `builtins.x` to a constant.

const std = @import("std");
const Scratch = @import("Scratch.zig");
const builtin = @import("builtin");
const ast_mod = @import("syntax/ast.zig");
const Ast = ast_mod.Ast;
const ExprId = ast_mod.ExprId;
const Sym = @import("syntax/symbol.zig").Sym;
const Pos = @import("syntax/pos.zig").Pos;
const ir = @import("eval/ir.zig");
const Ir = ir.Ir;
const Evaluator = @import("eval/Evaluator.zig");
const Value = @import("runtime/value.zig").Value;
const canonPath = Evaluator.canonPath;
const lint = @import("lint.zig");
const census = @import("runtime/census.zig");
const Allows = lint.allow.Allows;

pub const Error = Evaluator.Error;

const Scope = union(enum) {
    /// Slot `i` holds `names[start + i]` of the compiler's name stack; a
    /// large scope also gets a map.
    /// `base` is the env slot of the first name. `shares`: the slots extend
    /// the frame of the scope below (a lambda's body lambda or `let`)
    /// instead of opening an env of their own.
    lexical: struct { start: u32, len: u32, base: u32 = 0, shares: bool = false, map: ?*std.AutoHashMapUnmanaged(Sym, u32) = null },
    with,
};

/// Scopes up to this size are searched linearly.
const scan_max = 16;

/// The attrpath-merged bindings of a set, as eval.cc's `addAttr` builds them.
const Merged = struct {
    rec: bool,
    pos: Pos,
    statics: std.ArrayList(Static) = .empty,
    index: std.AutoHashMapUnmanaged(Sym, u32) = .empty,
    dynamics: std.ArrayList(Dynamic) = .empty,
    from_exprs: std.ArrayList(ExprId) = .empty,

    const Static = struct { sym: Sym, def: Def, pos: Pos };
    const Dynamic = struct { name: ExprId, def: Def, pos: Pos };

    /// The static binding of `s`. Most sets are small: they are searched,
    /// and `index` is built only once there are more than `scan_max`.
    fn find(m: *const Merged, s: Sym) ?u32 {
        if (m.statics.items.len <= scan_max) {
            for (m.statics.items, 0..) |st, i| if (st.sym == s) return @intCast(i);
            return null;
        }
        return m.index.get(s);
    }

    fn add(m: *Merged, gpa: std.mem.Allocator, st: Static) !void {
        try m.statics.append(gpa, st);
        const n = m.statics.items.len;
        if (n <= scan_max) return;
        errdefer _ = m.statics.pop();
        if (n == scan_max + 1) {
            for (m.statics.items, 0..) |x, i| try m.index.put(gpa, x.sym, @intCast(i));
        } else try m.index.put(gpa, st.sym, @intCast(n - 1));
    }

    fn deinit(m: *Merged, gpa: std.mem.Allocator) void {
        for (m.statics.items) |*s| s.def.deinit(gpa);
        for (m.dynamics.items) |*d| d.def.deinit(gpa);
        m.statics.deinit(gpa);
        m.index.deinit(gpa);
        m.dynamics.deinit(gpa);
        m.from_exprs.deinit(gpa);
    }
};

const Def = union(enum) {
    expr: ExprId,
    nested: *Merged,
    inherit: Sym,
    inherit_from: struct { idx: u32, name: Sym },

    fn deinit(d: *Def, gpa: std.mem.Allocator) void {
        if (d.* == .nested) {
            d.nested.deinit(gpa);
            gpa.destroy(d.nested);
        }
    }
};

ev: *Evaluator,
/// The compile's scratch arena: frees are no-ops, the whole lot goes at once.
gpa: std.mem.Allocator,
ast: *const Ast,
scopes: std.ArrayList(Scope) = .empty,
/// The names of every open lexical scope, innermost last.
names: std.ArrayList(Sym) = .empty,
/// Census only: the open lambdas, innermost last.
lambdas: if (census.enabled) std.ArrayList(OpenLambda) else void = if (census.enabled) .empty else {},
/// The directory of the file, for relative path literals.
base_dir: []const u8,
/// The global offset of the file's first byte.
base: u32,
home: []const u8,
/// A `~/` literal was compiled: the IR depends on `$HOME`.
used_home: bool = false,
/// The error of an `across` call that failed.
pending: Error = error.OutOfMemory,
s_builtins: Sym,
s_rev_count: Sym,
s_cur_pos: Sym,
s_overrides: Sym,
s_find_file: Sym,
s_nix_path: Sym,
/// The sorted start offsets of each symbol's variables and `inherit` names,
/// built on the file's first `x: e`.
var_uses: ?std.AutoHashMapUnmanaged(Sym, std.ArrayList(u32)) = null,
/// The lint levels the file compiles under; all off for an embedded source.
lints: *const lint.Config = &lint.Config.off,
/// The file's `# iets: allow` lines.
allows: *const Allows = &Allows.empty,
/// Where the warnings go, for the evaluator to report; messages in `ev.gpa`.
diags: ?*std.ArrayList(lint.Diag) = null,
/// A slice of a parallel compile: a site that would report fails the slice,
/// and the set compiles in order.
no_lints: bool = false,

const Compiler = @This();

/// The lints of one compile (docs/reference/lints.md).
pub const Lint = struct {
    /// The levels the file compiles under (`report.configForFile`).
    config: *const lint.Config,
    /// The source, for the text of its `# iets:` comments.
    src: []const u8,
    /// Out: the lines its `# iets: allow` comments cover, in `ev.gpa`.
    allows: *Allows,
    /// Out: the warnings, messages in `ev.gpa`.
    diags: *std.ArrayList(lint.Diag),
};

/// Compile a parsed file. `extra` names the attributes of a `scopedImport`
/// scope: a lexical frame around the whole file, slot `i` for `extra[i]`, so
/// they shadow the globals as in Nix.
/// `used_home`, when given, is set when the IR depends on `$HOME`.
/// `lints` is null for an embedded source, which is never linted.
pub fn compile(ev: *Evaluator, tree: *const Ast, base: u32, base_dir: []const u8, home: []const u8, extra: ?[]const Sym, used_home: ?*bool, lints: ?Lint) Error!ir.Ref {
    // Every temporary of a compile lives in one arena, reset for the next file.
    defer ev.local.compile_scratch.reset();
    var c: Compiler = .{
        .ev = ev,
        .gpa = ev.local.compile_scratch.allocator(),
        .ast = tree,
        .base_dir = base_dir,
        .base = base,
        .home = home,
        .s_builtins = try ev.sym("builtins"),
        .s_rev_count = ev.s.revCount,
        .s_cur_pos = try ev.sym("__curPos"),
        .s_overrides = try ev.sym("__overrides"),
        .s_find_file = try ev.sym("__findFile"),
        .s_nix_path = try ev.sym("__nixPath"),
    };
    defer {
        while (c.scopes.items.len > 0) c.popScope();
        c.scopes.deinit(c.gpa);
        c.names.deinit(c.gpa);
        if (census.enabled) c.lambdas.deinit(c.gpa);
    }
    if (extra) |names| try c.pushLexical(names);
    if (lints) |l| {
        c.lints = l.config;
        c.allows = l.allows;
        c.diags = l.diags;
        try c.parserNotes(l);
    }
    const code = try c.expr(tree.root);
    if (used_home) |u| u.* = c.used_home;
    return code;
}

/// The `# iets:` comments the lexer noted, resolved into the allow table,
/// then the URL literals and the unknown allow names, in the order Rust
/// iets reports them.
fn parserNotes(c: *Compiler, l: Lint) Error!void {
    var bad: std.ArrayList(lint.allow.Bad) = .empty;
    var bad_at: std.ArrayList(u32) = .empty;
    for (c.ast.allows.items) |a| {
        const before = bad.items.len;
        const mask = try lint.allow.parseComment(c.gpa, l.src[a.text.start..a.text.end], &bad);
        try l.allows.add(c.ev.gpa, a.line.start, a.line.end, mask);
        for (bad.items[before..]) |b| try bad_at.append(c.gpa, a.text.start + b.at);
    }
    if (!c.lints.on(.url_literal) and !c.lints.on(.unknown_allow)) return;
    for (c.ast.notes.items) |n| switch (n) {
        .url => |id| {
            const text = c.ast.singleLit(c.ast.expr(id).str) orelse "";
            const is_error = c.lints.level(.url_literal) == .@"error";
            try c.lintSite(.url_literal, c.posOf(id), "{f}", .{lint.legacy.UrlLiteral{ .text = text, .is_error = is_error }});
        },
    };
    for (bad.items, bad_at.items) |b, at| try c.lintSite(.unknown_allow, .at(c.base + at), "{s}", .{b.msg});
}

/// A lint site: nothing at `off` or on a line a `# iets: allow` comment
/// covers, a diagnostic for the evaluator to report at `warn`, a compile
/// error at `error`.
fn lintSite(c: *Compiler, id: lint.LintId, pos: Pos, comptime fmt: []const u8, args: anytype) Error!void {
    const level = c.lints.level(id);
    if (level == .off) return;
    if (pos != .none and c.allows.covers(@backingInt(pos) - c.base, id)) return;
    if (c.no_lints) return c.fail(.cancelled, pos, "a lint in a parallel slice", .{});
    switch (level) {
        .off => {},
        .warn => {
            const diags = c.diags orelse return;
            const msg = try std.fmt.allocPrint(c.ev.gpa, fmt, args);
            diags.append(c.ev.gpa, .{ .id = id, .pos = pos, .msg = msg }) catch |e| {
                c.ev.gpa.free(msg);
                return e;
            };
        },
        .@"error" => return c.fail(.lint, pos, "[{s}] " ++ fmt, .{id.name()} ++ args),
    }
}

/// A reference to the global `s` (a bare name, or the `x` of
/// `builtins.x`): the `currentTime` half of `impure-builtin`.
fn globalRef(c: *Compiler, s: Sym, pos: Pos) Error!void {
    if (!c.lints.on(.impure_builtin)) return;
    if (!lint.purity.isCurrentTime(c.ev.interner.name(s))) return;
    try c.lintSite(.impure_builtin, pos, "{s}", .{lint.purity.current_time_msg});
}

/// Whether `body` may read the variable `s`. Desugared syntax reads
/// `__`-names without naming them (`<p>` reads `__findFile`), so those
/// always count.
fn namedIn(c: *Compiler, s: Sym, body: ExprId) Error!bool {
    if (std.mem.startsWith(u8, c.ev.interner.name(s), "__")) return true;
    if (c.var_uses == null) c.var_uses = try varUses(c.gpa, c.ast);
    const offs = (c.var_uses.?.get(s) orelse return false).items;
    const span = c.ast.span(body);
    const i = std.sort.lowerBound(u32, offs, span.start, orderU32);
    return i < offs.len and offs[i] < span.end;
}

fn orderU32(a: u32, b: u32) std.math.Order {
    return std.math.order(a, b);
}

/// Children come before their parents in the tree, so each symbol's
/// offsets arrive nearly sorted and an insertion sort finishes them.
fn varUses(gpa: std.mem.Allocator, tree: *const Ast) Error!std.AutoHashMapUnmanaged(Sym, std.ArrayList(u32)) {
    var m: std.AutoHashMapUnmanaged(Sym, std.ArrayList(u32)) = .empty;
    const add = struct {
        fn f(map: *std.AutoHashMapUnmanaged(Sym, std.ArrayList(u32)), a: std.mem.Allocator, sym: Sym, off: u32) Error!void {
            const gop = try map.getOrPut(a, sym);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(a, off);
        }
    }.f;
    for (tree.tags.items, tree.data.items, tree.spans.items) |t, d, sp| if (t == .@"var") try add(&m, gpa, d.@"var", sp.start);
    for (tree.names.items) |n| try add(&m, gpa, n.sym, n.span.start);
    var it = m.valueIterator();
    while (it.next()) |l| std.sort.insertion(u32, l.items, {}, std.sort.asc(u32));
    return m;
}

fn posOf(c: *Compiler, id: ExprId) Pos {
    return .at(c.base + c.ast.span(id).start);
}

fn spanPos(c: *Compiler, s: ast_mod.Span) Pos {
    return .at(c.base + s.start);
}

inline fn alloc(c: *Compiler, node: Ir) Error!ir.Ref {
    return c.ev.irNode(node);
}

fn allocOne(c: *Compiler, comptime T: type, v: T) Error!*const T {
    const p = try c.ev.local.arena.create(T);
    p.* = v;
    return p;
}

/// `body(c, args...)` behind a real call that returns a pointer or null
/// in one register, with the error on the compiler: Zig returns an error
/// union through memory, and the reload at every level of the recursion
/// stalls store forwarding. Debug builds call `body` directly.
fn across(c: *Compiler, comptime body: anytype, args: anytype) callconv(ast_mod.inline_release) Error!Payload(body) {
    if (builtin.mode == .debug) return @call(.auto, body, .{c} ++ args);
    return @call(.never_inline, Shim(body).run, .{c} ++ args) orelse c.pending;
}

fn Payload(comptime body: anytype) type {
    return @typeInfo(@typeInfo(@TypeOf(body)).@"fn".return_type.?).error_union.payload;
}

/// The out-of-line half of `across`: `body` inlined, its error parked.
fn Shim(comptime body: anytype) type {
    const P = @typeInfo(@TypeOf(body)).@"fn".param_types;
    const T = ?Payload(body);
    return switch (P.len) {
        2 => struct {
            fn run(c: *Compiler, a: P[1].?) T {
                return @call(.always_inline, body, .{ c, a }) catch |e| {
                    c.pending = e;
                    return null;
                };
            }
        },
        3 => struct {
            fn run(c: *Compiler, a: P[1].?, b: P[2].?) T {
                return @call(.always_inline, body, .{ c, a, b }) catch |e| {
                    c.pending = e;
                    return null;
                };
            }
        },
        4 => struct {
            fn run(c: *Compiler, a: P[1].?, b: P[2].?, d: P[3].?) T {
                return @call(.always_inline, body, .{ c, a, b, d }) catch |e| {
                    c.pending = e;
                    return null;
                };
            }
        },
        else => @compileError("Shim takes one to three arguments"),
    };
}

fn fail(c: *Compiler, kind: Evaluator.ErrorKind, pos: Pos, comptime fmt: []const u8, args: anytype) Error {
    return c.ev.fail(kind, pos, fmt, args);
}

fn constant(c: *Compiler, v: Value) callconv(ast_mod.inline_release) Error!ir.Ref {
    return c.across(constantBody, .{v});
}

fn constantBody(c: *Compiler, v: Value) Error!ir.Ref {
    return c.alloc(.{ .constant = v });
}

// Scopes.

/// A lambda being compiled: the index in `scopes` its params start at, and
/// whether its body read a variable from below that. Atomic: the slices of
/// a huge set compile on several workers.
const OpenLambda = struct { frame: usize, captures: *std.atomic.Value(bool) };

/// Census: a variable read from scope index `s` captures every open lambda
/// whose frame sits above `s`.
fn noteCapture(c: *Compiler, s: usize) void {
    var i = c.lambdas.items.len;
    while (i > 0) {
        i -= 1;
        const l = c.lambdas.items[i];
        if (l.frame <= s) break;
        l.captures.store(true, .monotonic);
    }
}

fn lexicalLookup(c: *Compiler, s: Sym) bool {
    var i = c.scopes.items.len;
    while (i > 0) {
        i -= 1;
        switch (c.scopes.items[i]) {
            .lexical => if (c.slotIn(i, s) != null) return true,
            .with => {},
        }
    }
    return false;
}

fn hasWith(c: *Compiler) bool {
    for (c.scopes.items) |s| if (s == .with) return true;
    return false;
}

fn resolve(c: *Compiler, s: Sym, pos: Pos) callconv(ast_mod.inline_release) Error!ir.Ref {
    return c.across(resolveBody, .{ s, pos });
}

fn resolveBody(c: *Compiler, s: Sym, pos: Pos) Error!ir.Ref {
    if (s == c.s_cur_pos) return c.alloc(.{ .cur_pos = pos });
    var withs: std.ArrayList(u32) = .empty;
    defer withs.deinit(c.gpa);
    var depth: u32 = 0;
    var outermost_with: if (census.enabled) ?usize else void = if (census.enabled) null else {};
    var i = c.scopes.items.len;
    while (i > 0) {
        i -= 1;
        switch (c.scopes.items[i]) {
            .lexical => |l| {
                if (c.slotIn(i, s)) |idx| {
                    if (census.enabled) c.noteCapture(i);
                    return c.alloc(.{ .local = .{ .depth = depth, .idx = idx } });
                }
                if (l.shares) continue;
            },
            .with => {
                try withs.append(c.gpa, depth);
                if (census.enabled) outermost_with = i;
            },
        }
        depth += 1;
    }
    if (census.enabled) if (outermost_with) |w| c.noteCapture(w);
    // Globals live in Nix's static base env, a lexical scope, so they beat
    // any enclosing `with` (`with { true = 1; }; true` is `true`).
    if (c.ev.globals.get(s)) |v| {
        try c.globalRef(s, pos);
        return c.constant(v);
    }
    if (withs.items.len == 0) return c.fail(.undefined_var, pos, "undefined variable '{s}'", .{c.ev.interner.name(s)});
    return c.alloc(.{ .with_var = .{ .sym = s, .pos = pos, .withs = try c.ev.local.arena.dupe(u32, withs.items) } });
}

/// A lexical scope whose slot `i` is `names[i]`.
fn pushLexical(c: *Compiler, names: []const Sym) Error!void {
    return c.pushFrame(names, null);
}

/// A lexical scope whose names take slots from `base` on, in the env of the
/// scope below when `base` is given, else in an env of their own.
fn pushFrame(c: *Compiler, names: []const Sym, base: ?u32) Error!void {
    const start: u32 = @intCast(c.names.items.len);
    try c.names.appendSlice(c.gpa, names);
    errdefer c.names.shrinkRetainingCapacity(start);
    var map: ?*std.AutoHashMapUnmanaged(Sym, u32) = null;
    if (names.len > scan_max) {
        const m = try c.gpa.create(std.AutoHashMapUnmanaged(Sym, u32));
        m.* = .empty;
        errdefer {
            m.deinit(c.gpa);
            c.gpa.destroy(m);
        }
        try m.ensureTotalCapacity(c.gpa, @intCast(names.len));
        for (names, 0..) |n, i| m.putAssumeCapacity(n, @intCast(i));
        map = m;
    }
    try c.scopes.append(c.gpa, .{ .lexical = .{ .start = start, .len = @intCast(names.len), .base = base orelse 0, .shares = base != null, .map = map } });
}

fn popScope(c: *Compiler) void {
    const s = c.scopes.pop().?;
    if (s == .lexical) {
        c.names.shrinkRetainingCapacity(s.lexical.start);
        if (s.lexical.map) |m| {
            m.deinit(c.gpa);
            c.gpa.destroy(m);
        }
    }
}

/// The slot of `s` in scope `i`, if it binds it.
fn slotIn(c: *Compiler, i: usize, s: Sym) ?u32 {
    const l = c.scopes.items[i].lexical;
    if (l.map) |m| return if (m.get(s)) |k| l.base + k else null;
    for (c.names.items[l.start..][0..l.len], 0..) |n, k| if (n == s) return l.base + @as(u32, @intCast(k));
    return null;
}

// Expressions.

fn expr(c: *Compiler, id: ExprId) callconv(ast_mod.inline_release) Error!ir.Ref {
    return c.across(exprBody, .{id});
}

fn exprBody(c: *Compiler, id: ExprId) Error!ir.Ref {
    const pos = c.posOf(id);
    const a = c.ast;
    switch (a.expr(id)) {
        .int => |i| return c.constant(try c.ev.mkInt(i)),
        .float => |f| return c.constant(try c.ev.mkFloat(f)),
        .str => |parts| return c.string(a.partsOf(parts), pos),
        .path => |p| return c.pathLit(p.kind, a.partsOf(p.parts), pos),
        .@"var" => |s| return c.resolve(s, pos),
        .select => |s| {
            const path = a.elemsOf(s.path);
            if (c.lints.on(.impure_builtin)) if (c.builtinsRef(s.subject, path)) |first| try c.globalRef(first, pos);
            if (s.default == .none) if (try c.foldBuiltins(s.subject, path, pos)) |folded| return folded;
            if (path.len == 1) if (try c.attrName(path[0]) == .static) {
                const sym = (try c.attrName(path[0])).static;
                if (sym != c.s_rev_count) {
                    const subject = try c.expr(s.subject);
                    return c.alloc(.{ .select1 = .{
                        .subject = subject,
                        .sym = sym,
                        .default = if (s.default.unwrap()) |d| try c.expr(d) else null,
                        .pos = pos,
                    } });
                }
            };
            const sel = try c.allocOne(ir.Select, .{
                .subject = try c.expr(s.subject),
                .path = try c.attrPath(path),
                .default = if (s.default.unwrap()) |d| try c.expr(d) else null,
                .pos = pos,
            });
            // a path that names `revCount` reads the lazy count of a tree,
            // which reports `rev-count` at the selection
            for (sel.path) |e| if (e == .static and e.static == c.s_rev_count) return c.alloc(.{ .select_count = sel });
            return c.alloc(.{ .select = sel });
        },
        .has_attr => |h| return c.alloc(.{ .has_attr = .{ .subject = try c.expr(h.subject), .path = try c.attrPath(a.elemsOf(h.path)) } }),
        .attrs => |at| {
            var m = try c.mergeBinds(at.rec, a.bindsOf(at.binds), pos);
            defer m.deinit(c.gpa);
            if (m.statics.items.len == 0 and m.dynamics.items.len == 0) return c.constant(try c.ev.emptyAttrs());
            return c.alloc(.{ .attrs = try c.lowerAttrs(&m) });
        },
        .list => |items| {
            const ids = a.idsOf(items);
            if (ids.len == 0) return c.constant(try c.ev.mkList(&.{}));
            const out = try c.ev.local.arena.allocSlice(ir.Ref, ids.len);
            for (ids, out) |i, *o| o.* = try c.expr(i);
            return c.alloc(.{ .list = out });
        },
        .lambda, .lambda_pattern => return c.alloc(.{ .lambda = try c.lambda(id, null, null) }),
        .apply => |ap| {
            const func = try c.expr(ap.func);
            const ids = a.idsOf(ap.args);
            const args = try c.ev.local.arena.allocSlice(ir.Ref, ids.len);
            for (ids, args) |i, *o| o.* = try c.expr(i);
            return c.alloc(.{ .apply = .init(func, args, pos) });
        },
        .let => |l| return c.letIn(a.bindsOf(l.binds), l.body, pos, null),
        .with => |w| {
            const scope = try c.expr(w.scope);
            try c.scopes.append(c.gpa, .with);
            defer c.popScope();
            return c.alloc(.{ .with = .{ .scope = scope, .body = try c.expr(w.body), .pos = pos } });
        },
        .@"if" => |i| {
            const cond = try c.expr(i.cond);
            const then = try c.expr(i.then);
            const branches = try c.allocOne([2]ir.Ref, .{ then, try c.expr(i.@"else") });
            return c.alloc(.{ .@"if" = .{ .cond = cond, .branches = branches, .pos = c.posOf(i.cond) } });
        },
        .assert => |as| return c.alloc(.{ .assert = .{ .cond = try c.expr(as.cond), .body = try c.expr(as.body), .pos = pos } }),
        .unary => |u| {
            const e = try c.expr(u.expr);
            return c.alloc(switch (u.op) {
                .not => .{ .not = .{ .e = e, .pos = pos } },
                .neg => .{ .neg = .{ .e = e, .pos = pos } },
            });
        },
        .binary => |b| {
            const l = try c.expr(b.lhs);
            const r = try c.expr(b.rhs);
            const bin = struct {
                fn f(op: ir.BinOp, x: ir.Ref, y: ir.Ref, p: Pos) Ir {
                    return .{ .binop = .{ .op = op, .a = x, .b = y, .pos = p } };
                }
            }.f;
            return c.alloc(switch (b.op) {
                .eq => bin(.eq, l, r, pos),
                .ne => bin(.ne, l, r, pos),
                .lt => bin(.lt, l, r, pos),
                // parser.y desugars `a > b` to `__lessThan b a` and `a <= b` to
                // `!(__lessThan b a)`, so the right operand is evaluated first.
                .gt => bin(.lt, r, l, pos),
                .le => bin(.ge, r, l, pos),
                .ge => bin(.ge, l, r, pos),
                .@"and" => bin(.@"and", l, r, pos),
                .@"or" => bin(.@"or", l, r, pos),
                .impl => bin(.impl, l, r, pos),
                .update => bin(.update, l, r, pos),
                .concat => bin(.concat_lists, l, r, pos),
                .add => .{ .concat = .{ .force_string = false, .pos = pos, .parts = try c.ev.local.arena.dupe(ir.Ref, &.{ l, r }) } },
                .sub => bin(.sub, l, r, pos),
                .mul => bin(.mul, l, r, pos),
                .div => bin(.div, l, r, pos),
            });
        },
    }
}

/// The `x` of `builtins.x ...` on the unshadowed global.
fn builtinsRef(c: *Compiler, subject: ExprId, path: []const ast_mod.AttrElem) ?Sym {
    const s = switch (c.ast.expr(subject)) {
        .@"var" => |s| s,
        else => return null,
    };
    if (s != c.s_builtins or c.lexicalLookup(s)) return null;
    return switch (path[0]) {
        .static => |f| f,
        .dynamic => null,
    };
}

/// `builtins.x` on the unshadowed global, outside any `with`: the constant itself.
fn foldBuiltins(c: *Compiler, subject: ExprId, path: []const ast_mod.AttrElem, pos: Pos) Error!?ir.Ref {
    const s = switch (c.ast.expr(subject)) {
        .@"var" => |s| s,
        else => return null,
    };
    if (s != c.s_builtins or c.lexicalLookup(s) or c.hasWith()) return null;
    const b = c.ev.globals.get(c.s_builtins) orelse return null;
    if (b.kind() != .attrs) return null;
    const first = switch (path[0]) {
        .static => |f| f,
        .dynamic => return null,
    };
    const at = b.as(@import("runtime/value.zig").Attrs).get(first) orelse return null;
    const v = at.cell.get();
    if (v.isThunk()) return null;
    if (path.len == 1) return try c.constant(v);
    if (path.len == 2) if (try c.attrName(path[1]) == .static)
        return try c.alloc(.{ .select1 = .{ .subject = try c.constant(v), .sym = (try c.attrName(path[1])).static, .default = null, .pos = pos } });
    return try c.alloc(.{ .select = try c.allocOne(ir.Select, .{
        .subject = try c.constant(v),
        .path = try c.attrPath(path[1..]),
        .default = null,
        .pos = pos,
    }) });
}

fn attrPath(c: *Compiler, path: []const ast_mod.AttrElem) Error![]const ir.AttrElem {
    const out = try c.ev.local.arena.allocSlice(ir.AttrElem, path.len);
    for (path, out) |e, *o| o.* = switch (try c.attrName(e)) {
        .static => |s| .{ .static = s },
        .dynamic => |d| .{ .dynamic = try c.expr(d) },
    };
    return out;
}

const Name = union(enum) { static: Sym, dynamic: ExprId };

/// A dynamic element that is a constant string is static.
fn attrName(c: *Compiler, e: ast_mod.AttrElem) Error!Name {
    switch (e) {
        .static => |s| return .{ .static = s },
        .dynamic => |id| {
            if (c.ast.expr(id) == .str) if (c.ast.singleLit(c.ast.expr(id).str)) |lit|
                return .{ .static = try c.ev.sym(lit) };
            return .{ .dynamic = id };
        },
    }
}

fn strPart(c: *Compiler, p: ast_mod.StrPart) Error!ir.Ref {
    return switch (p) {
        .lit => |l| c.constant(try c.ev.mkString(c.ast.bytesOf(l))),
        .interp => |e| c.expr(e),
    };
}

fn string(c: *Compiler, parts: []const ast_mod.StrPart, pos: Pos) callconv(ast_mod.inline_release) Error!ir.Ref {
    return c.across(stringBody, .{ parts, pos });
}

fn stringBody(c: *Compiler, parts: []const ast_mod.StrPart, pos: Pos) Error!ir.Ref {
    var all_lit = true;
    for (parts) |p| if (p == .interp) {
        all_lit = false;
    };
    if (all_lit) {
        if (parts.len == 1) return c.constant(try c.ev.mkString(c.ast.bytesOf(parts[0].lit)));
        var bytes: std.ArrayList(u8) = .empty;
        for (parts) |p| try bytes.appendSlice(c.gpa, c.ast.bytesOf(p.lit));
        return c.constant(try c.ev.mkString(bytes.items));
    }
    const out = try c.ev.local.arena.allocSlice(ir.Ref, parts.len);
    for (parts, out) |p, *o| o.* = try c.strPart(p);
    return c.alloc(.{ .concat = .{ .force_string = true, .pos = pos, .parts = out } });
}

fn pathLit(c: *Compiler, kind: ast_mod.PathKind, parts: []const ast_mod.StrPart, pos: Pos) Error!ir.Ref {
    if (kind == .search) {
        const name = try c.string(parts, pos);
        // `<x>` is `__findFile __nixPath "x"`, so a local `__nixPath` or
        // `__findFile` takes part, as in Nix.
        if (c.lexicalLookup(c.s_find_file) or c.lexicalLookup(c.s_nix_path) or c.hasWith()) {
            const func = try c.resolve(c.s_find_file, pos);
            const np = try c.resolve(c.s_nix_path, pos);
            return c.alloc(.{ .apply = .init(func, try c.ev.local.arena.dupe(ir.Ref, &.{ np, name }), pos) });
        }
        return c.alloc(.{ .search_path = .{ .name = name, .pos = pos } });
    }
    var all_lit = true;
    for (parts) |p| if (p == .interp) {
        all_lit = false;
    };
    const first_lit: []const u8 = if (parts.len > 0 and parts[0] == .lit) c.ast.bytesOf(parts[0].lit) else "";
    // parser.y `path_start`: `lint-absolute-path-literals` and `lint-short-path-literals`
    if (c.lints.on(.absolute_path_literal) or c.lints.on(.short_path_literal)) if (lint.path.pathLiteral(kind, first_lit)) |id| {
        try c.lintSite(id, pos, "{f}", .{lint.path.Message{ .kind = kind, .lit = first_lit }});
    };
    const trailing_slash = std.mem.endsWith(u8, first_lit, "/") and !all_lit;
    const scratch = c.ev.local.arena.allocator();
    var resolved: []const u8 = switch (kind) {
        .absolute => try canonPath(scratch, first_lit),
        .relative => try canonPath(scratch, try std.mem.concat(scratch, u8, &.{ c.base_dir, "/", first_lit })),
        // parser.y's HPATH rule joins `$HOME` and the text without absPath,
        // so `~/a/../b` keeps its `..`.
        .home => blk: {
            c.used_home = true;
            break :blk try std.mem.concat(scratch, u8, &.{ c.home, first_lit });
        },
        .search => unreachable,
    };
    if (trailing_slash and !std.mem.endsWith(u8, resolved, "/")) resolved = try std.mem.concat(scratch, u8, &.{ resolved, "/" });
    const first = try c.constant(try c.ev.mkPath(resolved));
    if (all_lit) return first;
    const rest = if (parts[0] == .lit) parts[1..] else parts;
    const out = try c.ev.local.arena.allocSlice(ir.Ref, rest.len + 1);
    out[0] = first;
    for (rest, out[1..]) |p, *o| o.* = try c.strPart(p);
    return c.alloc(.{ .concat = .{ .force_string = false, .pos = pos, .parts = out } });
}

// Bindings.

fn mergeBinds(c: *Compiler, rec: bool, binds: []const ast_mod.Bind, pos: Pos) Error!Merged {
    var m: Merged = .{ .rec = rec, .pos = pos };
    errdefer m.deinit(c.gpa);
    for (binds) |*b| try c.addBind(&m, b);
    return m;
}

fn addBind(c: *Compiler, m: *Merged, b: *const ast_mod.Bind) Error!void {
    const pos = c.spanPos(b.span);
    switch (b.kind) {
        .value => |v| try c.addPath(m, c.ast.elemsOf(v.path), .{ .expr = v.value }, pos),
        .inherit => |inh| {
            const names = c.ast.namesOf(inh.names);
            if (inh.from == .none) {
                for (names) |n| try c.addStatic(m, n.sym, .{ .inherit = n.sym }, c.spanPos(n.span));
            } else {
                const idx: u32 = @intCast(m.from_exprs.items.len);
                try m.from_exprs.append(c.gpa, inh.from);
                for (names) |n| try c.addStatic(m, n.sym, .{ .inherit_from = .{ .idx = idx, .name = n.sym } }, c.spanPos(n.span));
            }
        },
    }
}

fn newNested(c: *Compiler, pos: Pos) Error!*Merged {
    const n = try c.gpa.create(Merged);
    n.* = .{ .rec = false, .pos = pos };
    return n;
}

fn addPath(c: *Compiler, m: *Merged, p: []const ast_mod.AttrElem, def: Def, pos: Pos) Error!void {
    var cur = m;
    for (p[0 .. p.len - 1]) |elem| {
        switch (try c.attrName(elem)) {
            .static => |s| {
                if (cur.find(s)) |i| {
                    try c.openNested(cur, i, pos);
                    cur = cur.statics.items[i].def.nested;
                } else {
                    const n = try c.newNested(pos);
                    try cur.add(c.gpa, .{ .sym = s, .def = .{ .nested = n }, .pos = pos });
                    cur = n;
                }
            },
            .dynamic => |e| {
                const n = try c.newNested(pos);
                try cur.dynamics.append(c.gpa, .{ .name = e, .def = .{ .nested = n }, .pos = pos });
                cur = n;
            },
        }
    }
    switch (try c.attrName(p[p.len - 1])) {
        .static => |s| try c.addStatic(cur, s, def, pos),
        .dynamic => |e| try cur.dynamics.append(c.gpa, .{ .name = e, .def = def, .pos = pos }),
    }
}

/// Turn an `a = { ... };` literal into a mergeable nested node.
fn openNested(c: *Compiler, m: *Merged, idx: u32, pos: Pos) Error!void {
    const st = &m.statics.items[idx];
    switch (st.def) {
        .nested => {},
        .expr => |e| switch (c.ast.expr(e)) {
            .attrs => |at| {
                const n = try c.gpa.create(Merged);
                errdefer c.gpa.destroy(n);
                n.* = try c.mergeBinds(at.rec, c.ast.bindsOf(at.binds), c.posOf(e));
                m.statics.items[idx].def = .{ .nested = n };
            },
            else => return c.dupAttr(st.sym, pos, st.pos),
        },
        else => return c.dupAttr(st.sym, pos, st.pos),
    }
}

fn dupAttr(c: *Compiler, s: Sym, pos: Pos, prev: Pos) Error {
    return c.fail(.eval, pos, "attribute '{s}' already defined at {f}", .{ c.ev.interner.name(s), c.ev.files.at(prev) });
}

fn addStatic(c: *Compiler, m: *Merged, s: Sym, def_in: Def, pos: Pos) Error!void {
    var def = def_in;
    if (m.find(s)) |i| {
        // Both sides set literals: merge them (Nix drops the inner `rec`).
        const new_binds: ?[]const ast_mod.Bind = switch (def) {
            .expr => |e| switch (c.ast.expr(e)) {
                .attrs => |at| c.ast.bindsOf(at.binds),
                else => null,
            },
            .nested => &.{},
            else => null,
        };
        if (new_binds == null) {
            def.deinit(c.gpa);
            return c.dupAttr(s, pos, m.statics.items[i].pos);
        }
        c.openNested(m, i, pos) catch |e| {
            def.deinit(c.gpa);
            return e;
        };
        const target = m.statics.items[i].def.nested;
        if (def == .nested) {
            const src = def.nested;
            defer c.gpa.destroy(src);
            defer src.deinit(c.gpa);
            for (src.statics.items) |*st| {
                const d = st.def;
                st.def = .{ .expr = .none };
                try c.addStatic(target, st.sym, d, st.pos);
            }
            for (src.dynamics.items) |*dy| {
                try target.dynamics.append(c.gpa, dy.*);
                dy.def = .{ .expr = .none };
            }
        } else {
            for (new_binds.?) |*b| try c.addBind(target, b);
        }
        return;
    }
    errdefer def.deinit(c.gpa);
    try m.add(c.gpa, .{ .sym = s, .def = def, .pos = pos });
}

fn symLess(_: void, a: Merged.Static, b: Merged.Static) bool {
    return @backingInt(a.sym) < @backingInt(b.sym);
}

fn bindLess(_: void, a: ir.Bind, b: ir.Bind) bool {
    return @backingInt(a.sym) < @backingInt(b.sym);
}

fn lowerAttrs(c: *Compiler, m: *Merged) callconv(ast_mod.inline_release) Error!*const ir.Attrs {
    return c.across(lowerAttrsBody, .{m});
}

fn lowerAttrsBody(c: *Compiler, m: *Merged) Error!*const ir.Attrs {
    if (m.rec) {
        const binds, const from = try c.lowerRecBinds(m, null);
        defer c.popScope();
        // A rec set's dynamic attributes are evaluated in its env.
        const dynamic = try c.lowerDynamics(m);
        var overrides: ?u32 = null;
        for (binds, 0..) |b, i| if (b.sym == c.s_overrides) {
            overrides = @intCast(i);
        };
        return c.allocOne(ir.Attrs, .{ .rec = true, .pos = m.pos, .binds = binds, .from = from, .dynamic = dynamic, .overrides = overrides });
    }
    const binds = try c.ev.local.arena.allocSlice(ir.Bind, m.statics.items.len);
    const from = try c.ev.local.arena.allocSlice(ir.Ref, m.from_exprs.items.len);
    for (m.from_exprs.items, from) |e, *o| o.* = try c.expr(e);
    if (!try c.lowerStaticsParallel(m.statics.items, binds))
        for (m.statics.items, binds) |*st, *b| try c.lowerStatic(st, b);
    const dynamic = try c.lowerDynamics(m);
    std.sort.pdq(ir.Bind, binds, {}, bindLess);
    return c.allocOne(ir.Attrs, .{ .rec = false, .pos = m.pos, .binds = binds, .from = from, .dynamic = dynamic, .overrides = null });
}

/// One binding of a plain set.
fn lowerStatic(c: *Compiler, st: *const Merged.Static, b: *ir.Bind) Error!void {
    b.* = .{ .sym = st.sym, .pos = st.pos, .scope = .own, .value = undefined };
    switch (st.def) {
        .expr => |e| b.value = try c.valueExpr(e, st.sym),
        .nested => |n| b.value = try c.alloc(.{ .attrs = try c.lowerAttrs(n) }),
        .inherit => |v| b.value = try c.resolve(v, st.pos),
        .inherit_from => |f| {
            // The from-env holds the sources in anonymous slots at depth 0.
            b.scope = .from;
            b.value = try c.inheritFrom(f.idx, f.name, st.pos);
        },
    }
}

/// Plain sets with this many bindings have them compiled on several
/// workers (hackage-packages.nix: 19k).
const par_min = 2048;

/// `lowerStatic` for every binding, in slices on idle workers; false when
/// the set is too small, there are no workers, or a slice failed or met a
/// lint site that reports: the caller then compiles them in order, so the
/// first error and the warnings come as ever.
fn lowerStaticsParallel(c: *Compiler, statics: []const Merged.Static, binds: []ir.Bind) Error!bool {
    const pool = c.ev.pool orelse return false;
    if (statics.len < par_min) return false;
    // Read by every slice, so made before them.
    if (c.var_uses == null) c.var_uses = try varUses(c.gpa, c.ast);
    const n: u32 = @intCast(@min(Evaluator.Jobs.max, pool.workers.len * 4, statics.len / 256));
    var job: StaticsJob = .{ .c = c, .statics = statics, .binds = binds, .n = n };
    c.ev.runJobs(n, &job, StaticsJob.run);
    if (job.failed.load(.acquire)) return false;
    if (job.used_home.load(.acquire)) c.used_home = true;
    return true;
}

const StaticsJob = struct {
    c: *const Compiler,
    statics: []const Merged.Static,
    binds: []ir.Bind,
    n: u32,
    failed: std.atomic.Value(bool) = .init(false),
    used_home: std.atomic.Value(bool) = .init(false),

    /// Slice `i` with a compiler of its own: this worker's evaluator, a
    /// scratch of its own, copies of the scope stacks.
    fn run(ctx: *anyopaque, i: u32, ev: *Evaluator) void {
        const j: *StaticsJob = @ptrCast(@alignCast(ctx));
        const lo = j.statics.len * i / j.n;
        const hi = j.statics.len * (i + 1) / j.n;
        var scratch: Scratch = .init(ev.gpa);
        defer scratch.deinit();
        var cc = j.c.*;
        cc.ev = ev;
        cc.gpa = scratch.allocator();
        cc.used_home = false;
        cc.no_lints = true;
        cc.scopes = .empty;
        cc.names = .empty;
        cc.scopes.appendSlice(cc.gpa, j.c.scopes.items) catch return j.failed.store(true, .release);
        cc.names.appendSlice(cc.gpa, j.c.names.items) catch return j.failed.store(true, .release);
        if (census.enabled) {
            cc.lambdas = .empty;
            cc.lambdas.appendSlice(cc.gpa, j.c.lambdas.items) catch return j.failed.store(true, .release);
        }
        for (j.statics[lo..hi], j.binds[lo..hi]) |*st, *b| cc.lowerStatic(st, b) catch {
            ev.clearFailure();
            return j.failed.store(true, .release);
        };
        if (cc.used_home) j.used_home.store(true, .release);
    }
};

fn inheritFrom(c: *Compiler, slot: u32, name: Sym, pos: Pos) Error!ir.Ref {
    const subject = try c.alloc(.{ .local = .{ .depth = 0, .idx = slot } });
    if (name == c.s_rev_count) return c.alloc(.{ .select_count = try c.allocOne(ir.Select, .{
        .subject = subject,
        .path = try c.ev.local.arena.dupe(ir.AttrElem, &.{.{ .static = name }}),
        .default = null,
        .pos = pos,
    }) });
    return c.alloc(.{ .select1 = .{ .subject = subject, .sym = name, .default = null, .pos = pos } });
}

fn lowerDynamics(c: *Compiler, m: *Merged) Error![]const ir.DynBind {
    const out = try c.ev.local.arena.allocSlice(ir.DynBind, m.dynamics.items.len);
    for (m.dynamics.items, out) |d, *o| o.* = .{
        .name = try c.expr(d.name),
        .pos = d.pos,
        .value = switch (d.def) {
            .expr => |e| try c.expr(e),
            .nested => |n| try c.alloc(.{ .attrs = try c.lowerAttrs(n) }),
            else => unreachable,
        },
    };
    return out;
}

/// The bindings of `rec { }` and `let`. Pushes the new scope and leaves it
/// for the caller to compile the body in and pop.
/// With `base`, the slots extend the frame of the lambda the `let` is the
/// body of, from slot `base` on.
fn lowerRecBinds(c: *Compiler, m: *Merged, base: ?u32) Error!struct { []const ir.Bind, []const ir.Ref } {
    std.sort.pdq(Merged.Static, m.statics.items, {}, symLess);
    const statics = m.statics.items;
    const binds = try c.ev.local.arena.allocSlice(ir.Bind, statics.len);
    // `inherit x` resolves in the enclosing scope, before the new frame.
    for (statics, binds) |st, *b| {
        b.* = .{ .sym = st.sym, .pos = st.pos, .scope = .own, .value = undefined };
        if (st.def == .inherit) {
            b.value = try c.resolve(st.def.inherit, st.pos);
            b.scope = .outer;
        }
    }
    const names = try c.gpa.alloc(Sym, statics.len);
    defer c.gpa.free(names);
    for (statics, names) |st, *n| n.* = st.sym;
    try c.pushFrame(names, base);
    errdefer c.popScope();
    const at = base orelse 0;
    for (statics, binds) |st, *b| switch (st.def) {
        .expr => |e| b.value = try c.valueExpr(e, st.sym),
        .nested => |n| b.value = try c.alloc(.{ .attrs = try c.lowerAttrs(n) }),
        .inherit => {},
        .inherit_from => |f| b.value = try c.inheritFrom(@intCast(at + statics.len + f.idx), f.name, st.pos),
    };
    const from = try c.ev.local.arena.allocSlice(ir.Ref, m.from_exprs.items.len);
    for (m.from_exprs.items, from) |e, *o| o.* = try c.expr(e);
    return .{ binds, from };
}

/// `let`; with `base`, its slots extend the frame of the lambda it is the
/// body of, from slot `base` on.
fn letIn(c: *Compiler, binds: []const ast_mod.Bind, body: ExprId, pos: Pos, base: ?u32) Error!ir.Ref {
    var m = try c.mergeBinds(true, binds, pos);
    defer m.deinit(c.gpa);
    if (m.dynamics.items.len > 0) return c.fail(.eval, pos, "dynamic attributes not allowed in let", .{});
    const b, const from = try c.lowerRecBinds(&m, base);
    defer c.popScope();
    const body_ir = try c.expr(body);
    return c.alloc(.{ .let = try c.allocOne(ir.Let, .{ .binds = b, .from = from, .body = body_ir, .base = base orelse ir.Let.own_env }) });
}

/// A binding's value; a lambda is named after its binding.
fn valueExpr(c: *Compiler, e: ExprId, name: Sym) callconv(ast_mod.inline_release) Error!ir.Ref {
    return c.across(valueExprBody, .{ e, name });
}

fn valueExprBody(c: *Compiler, e: ExprId, name: Sym) Error!ir.Ref {
    return switch (c.ast.tag(e)) {
        .lambda, .lambda_pattern => c.alloc(.{ .lambda = try c.lambda(e, name, null) }),
        else => c.expr(e),
    };
}

fn formalLess(_: void, a: ast_mod.Formal, b: ast_mod.Formal) bool {
    return @backingInt(a.name) < @backingInt(b.name);
}

/// With `base`, the lambda is the body of another and its params extend
/// that lambda's frame from slot `base` on.
fn lambda(c: *Compiler, id: ExprId, name: ?Sym, base: ?u32) callconv(ast_mod.inline_release) Error!*const ir.Lambda {
    if (census.enabled) return c.censusLambda(id, name, base);
    return c.across(lambdaInner, .{ id, name, base });
}

/// `lambda`, noting whether its body captured a variable: open while it
/// compiles, a lambda is closed unless `noteCapture` marked it.
fn censusLambda(c: *Compiler, id: ExprId, name: ?Sym, base: ?u32) Error!*const ir.Lambda {
    var captures: std.atomic.Value(bool) = .init(false);
    try c.lambdas.append(c.gpa, .{ .frame = c.scopes.items.len, .captures = &captures });
    defer _ = c.lambdas.pop();
    const l = try c.across(lambdaInner, .{ id, name, base });
    @constCast(l).closed = !captures.load(.monotonic);
    return l;
}

fn lambdaInner(c: *Compiler, id: ExprId, name: ?Sym, base: ?u32) Error!*const ir.Lambda {
    const pos = c.posOf(id);
    const at = base orelse 0;
    switch (c.ast.expr(id)) {
        .lambda => |l| {
            // `x: e` where `e` never names `x` has no frame: the body runs
            // in the closure's env.
            if (!try c.namedIn(l.arg, l.body))
                return c.allocOne(ir.Lambda, .{ .param = .ident, .body = try c.expr(l.body), .pos = pos, .name = name, .arg = l.arg, .no_env = true });
            try c.pushFrame(&.{l.arg}, base);
            defer c.popScope();
            const body = try c.lambdaBody(l.body, at + 1);
            return c.allocOne(ir.Lambda, .{ .param = .ident, .body = body, .pos = pos, .name = name, .arg = l.arg, .base = at, .frame = frameEnd(body, at + 1) });
        },
        .lambda_pattern => |lp| {
            const pat = c.ast.pattern(lp.pattern);
            const sorted = try c.gpa.dupe(ast_mod.Formal, c.ast.formalsOf(pat.formals));
            defer c.gpa.free(sorted);
            std.sort.pdq(ast_mod.Formal, sorted, {}, formalLess);
            for (1..@max(sorted.len, 1)) |i| if (sorted[i].name == sorted[i - 1].name)
                return c.fail(.parse, c.spanPos(sorted[i].span), "duplicate formal function argument '{s}'", .{c.ev.interner.name(sorted[i].name)});
            const off: u32 = @intFromBool(pat.bind != null);
            const names = try c.gpa.alloc(Sym, sorted.len + off);
            defer c.gpa.free(names);
            if (pat.bind) |b| names[0] = b;
            for (sorted, names[off..]) |f, *n| n.* = f.name;
            try c.pushFrame(names, base);
            defer c.popScope();
            const formals = try c.ev.local.arena.allocSlice(ir.Formal, sorted.len);
            for (sorted, formals) |f, *o| o.* = .{
                .sym = f.name,
                .pos = c.spanPos(f.span),
                .default = if (f.default.unwrap()) |d| try c.expr(d) else null,
            };
            const end: u32 = at + @as(u32, @intCast(names.len));
            const body = try c.lambdaBody(lp.body, end);
            return c.allocOne(ir.Lambda, .{
                .param = .{ .formals = .{ .has_bind = pat.bind != null, .ellipsis = pat.ellipsis, .formals = formals } },
                .body = body,
                .pos = pos,
                .name = name,
                .arg = pat.bind,
                .base = at,
                .frame = frameEnd(body, end),
            });
        },
        else => unreachable,
    }
}

/// The body of a lambda whose frame has `end` slots: a lambda or `let` there
/// extends that frame instead of opening its own. An empty frame (`{ }:`) is
/// not extended: `base` 0 marks a lambda with an env of its own.
fn lambdaBody(c: *Compiler, body: ExprId, end: u32) callconv(ast_mod.inline_release) Error!ir.Ref {
    return c.across(frameBody, .{ body, end });
}

fn frameBody(c: *Compiler, body: ExprId, end: u32) Error!ir.Ref {
    if (end == 0) return c.expr(body);
    return switch (c.ast.expr(body)) {
        .lambda, .lambda_pattern => c.alloc(.{ .lambda = try c.lambda(body, null, end) }),
        .let => |l| c.letIn(c.ast.bindsOf(l.binds), l.body, c.posOf(body), end),
        else => c.expr(body),
    };
}

/// Slots of a lambda's env: `end` after its params, or past the bindings of
/// a `let` body that extends the frame.
fn frameEnd(body: ir.Ref, end: u32) u32 {
    return switch (body.*) {
        .let => |l| if (l.base != ir.Let.own_env) l.base + @as(u32, @intCast(l.binds.len + l.from.len)) else end,
        else => end,
    };
}
