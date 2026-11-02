//! The value representation. A `Value` is one 8-byte word with a 3-bit tag in
//! the low bits; heap objects are 8-aligned, live in a bump arena, and are never
//! freed. Layout rationale: ../iets/docs/explanation/evaluation.md.

const std = @import("std");
const Sym = @import("../syntax/symbol.zig").Sym;
const Pos = @import("../syntax/pos.zig").Pos;
const ir = @import("../eval/ir.zig");
const Arena = @import("Arena.zig");
const census = @import("census.zig");

/// The arena of the thread running, where a union's flat copy is made; null
/// outside an evaluation. A fiber moves between threads, so only
/// `Union.flatten`, which never parks and is never inlined, reads it: LLVM
/// cannot keep its address across a park there.
pub threadlocal var flat_arena: ?*Arena = null;

pub const Tag = enum(u3) {
    /// Pointer to a heap object that starts with a `Kind` byte.
    ptr = 0b000,
    /// 61-bit immediate integer.
    int = 0b001,
    /// Pointer to a `Thunk`: IR in an env.
    thunk = 0b010,
    /// `null`, `true`, `false` and the evaluator's markers.
    imm = 0b011,
    /// Pointer to a `Lambda`; the tag replaces the kind byte so a closure is two words.
    lambda = 0b101,
    /// Pointer to a `ThunkApp`: a suspended `f x`.
    thunk_app = 0b110,
    /// A `mapAttrs` entry: a `MapDesc` pointer and an entry index, no object.
    thunk_map = 0b100,
};

const tag_mask: u64 = 0b111;

pub const int_min: i64 = -(1 << 60);
pub const int_max: i64 = (1 << 60) - 1;

pub const Value = enum(u64) {
    null = imm(0),
    true = imm(1),
    false = imm(2),
    /// A thunk's state while it is being forced.
    blackhole = imm(3),
    /// A thunk's state after it was forced, and an env slot not written yet.
    empty = imm(4),
    /// The evaluator's internal "an error is pending"; never stored anywhere.
    failed = imm(5),
    /// A thunk's state after a helper forced it ahead of demand: forced, but
    /// not yet asked for, so the printers still show `<CODE>`.
    speculated = imm(6),
    /// `speculated`, with effects parked on the thunk (`eval/effects.zig`):
    /// a reader that sees the plain mark need not look them up.
    speculated_fx = imm(7),
    _,

    fn imm(comptime n: u64) u64 {
        return n << 3 | @backingInt(Tag.imm);
    }

    // A blackhole carries its claimer and whether anyone waits for it:
    // `id << 9 | waiters << 8 | blackhole`. The sequential path's is plain.

    pub inline fn isBlackhole(v: Value) bool {
        return v.bits() & 0xff == @backingInt(Value.blackhole);
    }

    pub inline fn blackholeOf(id: u32) Value {
        return @fromBackingInt(@intCast(@as(u64, id) << 9 | @backingInt(Value.blackhole)));
    }

    pub inline fn claimer(v: Value) u32 {
        return @intCast(v.bits() >> 9);
    }

    pub const waiters_bit: u64 = 0x100;

    pub inline fn hasWaiters(v: Value) bool {
        return v.bits() & waiters_bit != 0;
    }

    pub inline fn withWaiters(v: Value) Value {
        return @fromBackingInt(@intCast(v.bits() | 0x100));
    }

    pub inline fn bits(v: Value) u64 {
        return @backingInt(v);
    }

    pub inline fn tag(v: Value) Tag {
        return @fromBackingInt(@intCast(v.bits() & tag_mask));
    }

    pub inline fn fromBool(b: bool) Value {
        return if (b) .true else .false;
    }

    pub inline fn fitsImm(i: i64) bool {
        return i >= int_min and i <= int_max;
    }

    pub inline fn immInt(i: i64) Value {
        std.debug.assert(fitsImm(i));
        return @fromBackingInt(@intCast(@as(u64, @bitCast(i << 3)) | @backingInt(Tag.int)));
    }

    pub inline fn fromPtr(comptime t: Tag, p: anytype) Value {
        const a = @intFromPtr(p);
        std.debug.assert(a & tag_mask == 0);
        return @fromBackingInt(@intCast(a | @backingInt(t)));
    }

    /// The word for entry `i` of a `mapAttrs` result.
    pub inline fn mapEntry(d: *MapDesc, i: usize) Value {
        const a = @intFromPtr(d);
        std.debug.assert(a & tag_mask == 0 and a >> 47 == 0 and i < MapDesc.max_entries);
        return @fromBackingInt(@intCast((a >> 3) << 19 | @as(u64, i) << 3 | @backingInt(Tag.thunk_map)));
    }

    pub inline fn mapDesc(v: Value) struct { *MapDesc, usize } {
        const b = v.bits();
        return .{ @ptrFromInt((b >> 19) << 3), (b >> 3) & 0xffff };
    }

    /// Every thunk kind is a `code` cell (the code, then the value) and a
    /// `state` cell (the payload, `blackhole` while forced, `empty` after).
    pub inline fn thunkCells(v: Value) struct { code: *Cell, state: *Cell } {
        if (v.tag() == .thunk_map) {
            const d, const i = v.mapDesc();
            return .{ .code = &d.out.raw()[i].cell, .state = &d.states()[i] };
        }
        const t = v.untagged(Thunk);
        return .{ .code = &t.code, .state = &t.state };
    }

    pub inline fn obj(v: Value) *Obj {
        std.debug.assert(v.tag() == .ptr);
        return @ptrFromInt(v.bits());
    }

    pub inline fn untagged(v: Value, comptime T: type) *T {
        return @ptrFromInt(v.bits() & ~tag_mask);
    }

    pub inline fn isThunk(v: Value) bool {
        return switch (v.tag()) {
            .thunk, .thunk_app, .thunk_map => true,
            else => false,
        };
    }

    /// A union reports itself as `.attrs`: it is one to every consumer.
    pub inline fn kind(v: Value) ?Kind {
        if (v.tag() != .ptr) return null;
        const k = v.obj().kind;
        return if (k == .attrs_union) .attrs else k;
    }

    /// A `//` result that has not been flattened, for the lookups that probe
    /// its leaves instead.
    pub inline fn asUnion(v: Value) ?*Union {
        if (v.tag() != .ptr or v.obj().kind != .attrs_union) return null;
        return @ptrFromInt(v.bits());
    }

    pub fn view(v: Value) View {
        return switch (v.tag()) {
            .int => .{ .int = @as(i64, @bitCast(v.bits())) >> 3 },
            .imm => switch (v) {
                .null => .null,
                .true => .{ .bool = true },
                .false => .{ .bool = false },
                else => unreachable,
            },
            .lambda => .{ .lambda = v.untagged(Lambda) },
            .thunk, .thunk_app, .thunk_map => .thunk,
            .ptr => switch (v.obj().kind) {
                .int => .{ .int = v.as(IntObj).val },
                .float => .{ .float = v.as(FloatObj).val },
                .string => .{ .string = v.as(String) },
                .path => .{ .path = v.as(Path) },
                .list => .{ .list = v.as(List) },
                .attrs, .attrs_union => .{ .attrs = v.as(Attrs) },
                .primop => .{ .primop = v.as(PrimOp) },
                .primop_app => .{ .primop_app = v.as(PrimOpApp) },
            },
        };
    }

    pub inline fn as(v: Value, comptime T: type) *T {
        std.debug.assert(v.kind() == T.kind_tag);
        if (T == Attrs) if (v.asUnion()) |u| return u.flat();
        if (census.enabled and T == String) @atomicStore(u8, &@as(*String, @ptrFromInt(v.bits())).flags, 1, .monotonic);
        return @ptrFromInt(v.bits());
    }

    /// `as` for a string its maker holds, which is not a use the census
    /// counts.
    pub inline fn asUnmarked(v: Value, comptime T: type) *T {
        std.debug.assert(v.kind() == T.kind_tag and T != Attrs);
        return @ptrFromInt(v.bits());
    }

    pub fn typeOf(v: Value) Type {
        return switch (v.tag()) {
            .int => .int,
            .imm => switch (v) {
                .null => .null,
                .true, .false => .bool,
                else => unreachable,
            },
            .lambda => .lambda,
            .thunk, .thunk_app, .thunk_map => .thunk,
            .ptr => switch (v.obj().kind) {
                .int => .int,
                .float => .float,
                .string => .string,
                .path => .path,
                .list => .list,
                .attrs, .attrs_union => .set,
                .primop, .primop_app => .lambda,
            },
        };
    }
};

pub const View = union(enum) {
    int: i64,
    float: f64,
    bool: bool,
    null,
    string: *String,
    path: *Path,
    list: *List,
    attrs: *Attrs,
    lambda: *Lambda,
    primop: *PrimOp,
    primop_app: *PrimOpApp,
    thunk,
};

/// The type names `builtins.typeOf` returns.
pub const Type = enum {
    int,
    float,
    bool,
    null,
    string,
    path,
    list,
    set,
    lambda,
    thunk,

    pub fn name(t: Type) []const u8 {
        return @tagName(t);
    }

    /// Mirrors eval.cc:showType, the type name in error messages.
    pub fn show(t: Type) []const u8 {
        return switch (t) {
            .int => "an integer",
            .float => "a float",
            .bool => "a Boolean",
            .null => "null",
            .string => "a string",
            .path => "a path",
            .list => "a list",
            .set => "a set",
            .lambda => "a function",
            .thunk => "a thunk",
        };
    }
};

/// An atomic slot holding a `Value`. Env slots, list elements and attribute
/// values are all cells, so one evaluator serves one thread or several.
pub const Cell = extern struct {
    raw: u64,

    pub inline fn init(v: Value) Cell {
        return .{ .raw = v.bits() };
    }

    pub inline fn get(c: *const Cell) Value {
        return @fromBackingInt(@intCast(@atomicLoad(u64, &c.raw, .acquire)));
    }

    pub inline fn set(c: *Cell, v: Value) void {
        @atomicStore(u64, &c.raw, v.bits(), .release);
    }
};

pub const Kind = enum(u8) {
    int = 1,
    float,
    string,
    path,
    list,
    attrs,
    primop,
    primop_app,
    /// A `//` result: see `Union`. Never seen outside this file and the lookups.
    attrs_union,
};

pub const Obj = extern struct {
    kind: Kind align(8),
};

/// Census marks (`census.zig`) in a set's or a union's header padding:
/// the producer, and the select count (low 7 bits, saturating) with bit 7
/// once the entries were iterated. Only in a `-Dstats2=true` build.
pub const Marks = extern struct { origin: u8 = 0, flags: u8 = 0 };
const SetMarks = if (census.enabled) Marks else void;
const no_marks: SetMarks = if (census.enabled) .{} else {};
/// Census only: set once a string was viewed, a list's cells read.
const Flag = if (census.enabled) u8 else void;
const no_flag: Flag = if (census.enabled) 0 else {};

/// The census marks of a set or a union.
pub fn setMarks(p: *Obj) *Marks {
    if (!census.enabled) unreachable;
    if (p.kind == .attrs_union) return &@as(*Union, @ptrCast(p)).marks;
    return &@as(*Attrs, @ptrCast(p)).marks;
}

inline fn markIterated(m: *Marks) void {
    _ = @atomicRmw(u8, &m.flags, .Or, census.iterated, .monotonic);
}

fn markSelected(m: *Marks) void {
    var f = @atomicLoad(u8, &m.flags, .monotonic);
    while (f & 0x7f < 0x7f) f = @cmpxchgWeak(u8, &m.flags, f, f + 1, .monotonic, .monotonic) orelse return;
}

pub const IntObj = extern struct {
    pub const kind_tag: Kind = .int;
    kind: Kind align(8) = kind_tag,
    val: i64,
};

pub const FloatObj = extern struct {
    pub const kind_tag: Kind = .float;
    kind: Kind align(8) = kind_tag,
    val: f64,
};

/// String context element. Ordered (`Ctx.order`) so contexts are sorted,
/// deduplicated slices that merge linearly.
pub const Ctx = struct {
    kind: CtxKind,
    /// The store path; for `built`, the derivation path, with one
    /// `<output>!` per layer of dynamic derivation above it.
    path: []const u8,
    /// The output name for `built`, empty otherwise.
    output: []const u8 = "",

    pub fn order(a: Ctx, b: Ctx) std.math.Order {
        if (a.kind != b.kind) return std.math.order(@backingInt(a.kind), @backingInt(b.kind));
        const o = std.mem.order(u8, a.path, b.path);
        if (o != .eq) return o;
        return std.mem.order(u8, a.output, b.output);
    }

    pub fn lessThan(_: void, a: Ctx, b: Ctx) bool {
        return a.order(b) == .lt;
    }

    pub fn isStore(c: Ctx) bool {
        return switch (c.kind) {
            .opaque_path, .drv_deep, .built => true,
            .impure_path, .impure_meta => false,
        };
    }
};

pub const CtxKind = enum(u8) {
    /// A store path referenced as-is.
    opaque_path,
    /// `=drv`: the whole derivation closure.
    drv_deep,
    /// `!out!drv`: one output of a derivation.
    built,
    /// Marks Nix does not have, invisible to `getContext`; the lints read
    /// them. Last so the store elements sort first.
    impure_path,
    impure_meta,
};

pub const String = extern struct {
    pub const kind_tag: Kind = .string;
    kind: Kind align(8) = kind_tag,
    flags: Flag = no_flag,
    /// The interned symbol of the bytes plus one, 0 until asked for.
    sym: u32 = 0,
    ptr: [*]const u8,
    len: usize,
    ctx_ptr: [*]const Ctx,
    ctx_len: usize,

    pub inline fn bytes(s: *const String) []const u8 {
        return s.ptr[0..s.len];
    }

    pub inline fn context(s: *const String) []const Ctx {
        return s.ctx_ptr[0..s.ctx_len];
    }

    pub fn cachedSym(s: *const String) ?Sym {
        const n = @atomicLoad(u32, &s.sym, .monotonic);
        return if (n == 0) null else @fromBackingInt(@intCast(n - 1));
    }

    /// Every thread computes the same symbol for the same bytes, so a race is harmless.
    pub fn cacheSym(s: *String, sym: Sym) void {
        @atomicStore(u32, &s.sym, @backingInt(sym) + 1, .monotonic);
    }
};

pub const Path = extern struct {
    pub const kind_tag: Kind = .path;
    kind: Kind align(8) = kind_tag,
    ptr: [*]const u8,
    len: usize,

    pub inline fn bytes(p: *const Path) []const u8 {
        return p.ptr[0..p.len];
    }
};

pub const List = extern struct {
    pub const kind_tag: Kind = .list;
    kind: Kind align(8) = kind_tag,
    flags: Flag = no_flag,
    len: u32,

    pub inline fn cells(l: *List) []Cell {
        if (census.enabled) @atomicStore(u8, &l.flags, 1, .monotonic);
        return l.raw();
    }

    /// The cells without a census mark, for filling a fresh list.
    pub inline fn raw(l: *List) []Cell {
        const base: [*]Cell = @ptrCast(@as([*]List, @ptrCast(l)) + 1);
        return base[0..l.len];
    }
};

pub const Attr = extern struct {
    sym: Sym align(8),
    pos: Pos,
    cell: Cell,
};

/// An attribute set: `len` attributes, sorted by symbol id, follow the header.
pub const Attrs = extern struct {
    pub const kind_tag: Kind = .attrs;
    kind: Kind align(8) = kind_tag,
    marks: SetMarks = no_marks,
    len: u32,

    pub inline fn attrs(a: *Attrs) []Attr {
        if (census.enabled) markIterated(&a.marks);
        return a.attrsBuf(a.len);
    }

    /// The entries without a census mark: filling a fresh set, and the
    /// merges of a union's leaves.
    pub inline fn raw(a: *Attrs) []Attr {
        return a.attrsBuf(a.len);
    }

    inline fn attrsBuf(a: *Attrs, n: usize) []Attr {
        const base: [*]Attr = @ptrCast(@as([*]Attrs, @ptrCast(a)) + 1);
        return base[0..n];
    }

    pub fn get(a: *Attrs, sym: Sym) ?*Attr {
        if (census.enabled) {
            markSelected(&a.marks);
            census.noteGet(0, 0);
        }
        return find(a.attrsBuf(a.len), sym);
    }

    /// `get` of a union's leaf or flat copy: the union counts the lookup.
    pub const getFlat = if (census.enabled) getUnmarked else get;

    fn getUnmarked(a: *Attrs, sym: Sym) ?*Attr {
        return find(a.raw(), sym);
    }

    inline fn find(items: []Attr, sym: Sym) ?*Attr {
        var lo: usize = 0;
        var hi: usize = items.len;
        const key = @backingInt(sym);
        // Small sets are the common case; a linear scan beats the branches.
        if (hi <= 8) {
            for (items) |*it| if (it.sym == sym) return it;
            return null;
        }
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const k = @backingInt(items[mid].sym);
            if (k == key) return &items[mid];
            if (k < key) lo = mid + 1 else hi = mid;
        }
        return null;
    }
};

/// `a // b` without the copy: the flat leaves of both sides, lowest priority
/// first. A lookup probes the leaves from the last; anything else asks for the
/// flat copy, made once. On nixpkgs most `//` results are only ever selected
/// from (docs/explanation/evaluation.md).
pub const Union = extern struct {
    kind: Kind align(8) = .attrs_union,
    nleaves: u8,
    marks: SetMarks = no_marks,
    /// Set once by whichever thread flattens first; every copy is equal.
    flat_cache: std.atomic.Value(?*Attrs) = .init(null),

    /// Leaves a union may hold; a lookup miss costs this many probes.
    pub const max_leaves = 8;
    /// Left operands smaller than this are merged flat: the copy is cheaper.
    pub const min_left = 8;

    pub inline fn leaves(u: *Union) []*Attrs {
        const base: [*]*Attrs = @ptrCast(@as([*]Union, @ptrCast(u)) + 1);
        return base[0..u.nleaves];
    }

    pub fn get(u: *Union, s: Sym) ?*Attr {
        if (census.enabled) u.noteGet(s);
        if (u.flat_cache.load(.acquire)) |f| return f.getFlat(s);
        const ls = u.leaves();
        var i = ls.len;
        while (i > 0) {
            i -= 1;
            if (ls[i].getFlat(s)) |a| return a;
        }
        return null;
    }

    /// Census: the lookup, and the leaves it probes.
    fn noteGet(u: *Union, s: Sym) void {
        markSelected(&u.marks);
        if (u.flat_cache.load(.acquire) != null) return census.noteGet(1, 0);
        const ls = u.leaves();
        var i = ls.len;
        while (i > 0) {
            i -= 1;
            if (ls[i].getFlat(s) != null) return census.noteGet(2, ls.len - i);
        }
        census.noteGet(4, ls.len);
    }

    /// The entries as one sorted set, a later leaf winning on equal names.
    pub fn flat(u: *Union) *Attrs {
        if (u.flat_cache.load(.acquire)) |f| return f;
        if (census.enabled) markIterated(&u.marks);
        const f = flatten(u.leaves()) catch @panic("out of memory");
        u.flat_cache.store(f, .release);
        return f;
    }

    /// The common two-leaf case, `b` over `a`.
    fn merge2(a: []Attr, b: []Attr, out: []Attr) usize {
        var i: usize = 0;
        var j: usize = 0;
        var n: usize = 0;
        while (i < a.len and j < b.len) : (n += 1) {
            const x = @backingInt(a[i].sym);
            const y = @backingInt(b[j].sym);
            if (x < y) {
                out[n] = a[i];
                i += 1;
            } else {
                out[n] = b[j];
                j += 1;
                if (x == y) i += 1;
            }
        }
        @memcpy(out[n..][0 .. a.len - i], a[i..]);
        @memcpy(out[n + a.len - i ..][0 .. b.len - j], b[j..]);
        return n + (a.len - i) + (b.len - j);
    }

    /// Bytes of flat copies made, for the statistics.
    pub var flat_bytes: std.atomic.Value(usize) = .init(0);

    /// `ls` merged into one set in the running thread's arena.
    pub noinline fn flatten(ls: []*Attrs) !*Attrs {
        // Merged into room for every entry, then cut to its size.
        var heads: usize = 0;
        for (ls) |l| heads += l.len;
        const size = @sizeOf(Attrs) + heads * @sizeOf(Attr);
        const a = flat_arena orelse {
            const bytes = try std.heap.smp_allocator.alignedAlloc(u8, .of(Attrs), size);
            const out: *Attrs = @ptrCast(bytes.ptr);
            out.* = .{ .len = @intCast(merge(ls, out.attrsBuf(heads))) };
            return out;
        };
        const p = try a.alloc(size);
        const out: *Attrs = @ptrCast(p);
        const n = merge(ls, out.attrsBuf(heads));
        out.* = .{ .len = @intCast(n) };
        const used = @sizeOf(Attrs) + n * @sizeOf(Attr);
        a.shrinkLast(p, size, used);
        if (census.enabled) a.census.noteAttrs(@ptrCast(out), .upd, n);
        _ = flat_bytes.fetchAdd(used, .monotonic);
        return out;
    }

    /// The leaves merged into `out`, a later leaf winning on equal names.
    /// The usual union is one big leaf and a few small ones, so a leaf that
    /// is ahead of all others copies its whole run at once.
    fn merge(ls: []*Attrs, out: []Attr) usize {
        if (ls.len == 2) return merge2(ls[0].raw(), ls[1].raw(), out);
        var heads: [max_leaves]usize = @splat(0);
        var n: usize = 0;
        while (true) {
            // The smallest head, the last leaf holding it, and the next head after it.
            var min: u32 = std.math.maxInt(u32);
            var next: u32 = std.math.maxInt(u32);
            var winner: usize = 0;
            var ties: usize = 0;
            for (ls, 0..) |l, k| if (heads[k] < l.len) {
                const id = @backingInt(l.raw()[heads[k]].sym);
                if (id < min) {
                    next = min;
                    min = id;
                    winner = k;
                    ties = 1;
                } else if (id == min) {
                    winner = k;
                    ties += 1;
                } else if (id < next) next = id;
            };
            if (ties == 0) return n;
            if (ties == 1) {
                const items = ls[winner].raw();
                var h = heads[winner];
                while (h < items.len and @backingInt(items[h].sym) < next) : (h += 1) {
                    out[n] = items[h];
                    n += 1;
                }
                heads[winner] = h;
                continue;
            }
            out[n] = ls[winner].raw()[heads[winner]];
            n += 1;
            for (ls, 0..) |l, k| {
                if (heads[k] < l.len and @backingInt(l.raw()[heads[k]].sym) == min) heads[k] += 1;
            }
        }
    }
};

/// Envs are reached only through `up`, closures and thunks, never through a
/// `Value`, so they carry no kind; slot counts come from the compiler.
pub const Env = extern struct {
    /// Read through `parent`: a census build keeps its marks in the low bits.
    up: ?*Env,

    pub inline fn parent(e: *Env) ?*Env {
        if (!census.enabled) return e.up;
        return @ptrFromInt(e.upWord().* & ~@as(usize, 7));
    }

    inline fn upWord(e: *Env) *usize {
        return @ptrCast(&e.up);
    }

    /// Census: a slot of this env was read.
    pub inline fn markRead(e: *Env) void {
        if (census.enabled) _ = @atomicRmw(usize, e.upWord(), .Or, 1, .monotonic);
    }

    /// Census: a thunk, closure or child env holds this env.
    pub inline fn markCaptured(e: *Env) void {
        if (census.enabled) _ = @atomicRmw(usize, e.upWord(), .Or, 2, .monotonic);
    }

    /// Census: the read (bit 0) and captured (bit 1) marks.
    pub fn marks(e: *Env) usize {
        return @atomicLoad(usize, e.upWord(), .monotonic) & 7;
    }

    pub inline fn slots(e: *Env) [*]Cell {
        return @ptrCast(@as([*]Env, @ptrCast(e)) + 1);
    }

    pub inline fn slot(e: *Env, i: usize) *Cell {
        return &e.slots()[i];
    }
};

pub const Lambda = extern struct {
    env: *Env,
    lam: *const ir.Lambda,
};

pub const PrimOp = extern struct {
    pub const kind_tag: Kind = .primop;
    kind: Kind align(8) = kind_tag,
    arity: u8,
    sym: Sym,
    name_ptr: [*]const u8,
    name_len: usize,
    f: *const anyopaque,

    pub fn name(p: *const PrimOp) []const u8 {
        return p.name_ptr[0..p.name_len];
    }
};

pub const PrimOpApp = extern struct {
    pub const kind_tag: Kind = .primop_app;
    kind: Kind align(8) = kind_tag,
    nargs: u32,
    op: *PrimOp,

    pub inline fn args(a: *PrimOpApp) []Value {
        const base: [*]Value = @ptrCast(@as([*]PrimOpApp, @ptrCast(a)) + 1);
        return base[0..a.nargs];
    }
};

/// A suspended `ir` in `env`, overwritten in place when forced. `state` holds
/// the env while unforced, `blackhole` during the force, `empty` after it;
/// `code` holds the IR until the force and the value after it.
pub const Thunk = extern struct {
    code: Cell,
    state: Cell,
};

/// A suspended `func arg`: `code` holds `func`, `state` holds `arg`. Forced
/// the same way as a `Thunk`.
pub const ThunkApp = Thunk;

/// One per `mapAttrs` call. Entry `i` of `out` starts as the map word
/// `(desc, i)`, a thunk with no object of its own: its code cell is the
/// entry's cell and its state is `states()[i]` (`null` until forced). Forcing
/// applies `f` to the name and entry `i` of `src`. On nixpkgs most entries
/// are never forced, so this is 8 bytes each instead of three objects.
pub const MapDesc = extern struct {
    f: Value,
    src: *Attrs,
    out: *Attrs,

    /// Larger sets take ordinary thunks.
    pub const max_entries = 1 << 16;

    pub inline fn states(d: *MapDesc) [*]Cell {
        return @ptrCast(@as([*]MapDesc, @ptrCast(d)) + 1);
    }
};

comptime {
    std.debug.assert(@sizeOf(String) == 40);
    std.debug.assert(@sizeOf(Attr) == 16);
    std.debug.assert(@sizeOf(Thunk) == 16);
}
