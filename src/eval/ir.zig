//! The resolved intermediate representation the evaluator walks. Every variable
//! is already a slot `(depth, idx)` in the env chain, or a `with_var` when no
//! lexical binder exists. Nodes live for the whole run, so thunks point at them.

const std = @import("std");
const census = @import("../runtime/census.zig");
const Sym = @import("../syntax/symbol.zig").Sym;
const Pos = @import("../syntax/pos.zig").Pos;
const Value = @import("../runtime/value.zig").Value;

pub const Ref = *const Ir;

pub const Ir = union(enum) {
    /// A literal, or a pre-resolved builtin.
    constant: Value,
    /// A lexical variable: walk `depth` envs up, read slot `idx`.
    local: struct { depth: u32, idx: u32 },
    /// A variable bound by `with`. `withs` lists, innermost first, the depth of
    /// each enclosing with-env relative to the current env.
    with_var: struct { sym: Sym, pos: Pos, withs: []const u32 },
    /// `__curPos`.
    cur_pos: Pos,
    /// `+` chains and interpolations. With `force_string` the result is a
    /// string even for a single path part; when the first part is a path the
    /// result is a path; ints and floats add.
    concat: struct { force_string: bool, pos: Pos, parts: []const Ref },
    /// `<name>`.
    search_path: struct { name: Ref, pos: Pos },
    /// `e.a.b or d` with a dynamic or longer path.
    select: *const Select,
    /// `e.name` and `e.name or d`, the common case, inline.
    select1: struct { subject: Ref, default: ?Ref, sym: Sym, pos: Pos },
    /// A `select` whose path names `revCount`: the read of a tree's lazy
    /// count reports `rev-count` at this selection (`lint/purity.zig`). A
    /// tag of its own keeps the test of the name out of the hot handlers.
    select_count: *const Select,
    has_attr: struct { subject: Ref, path: []const AttrElem },
    attrs: *const Attrs,
    list: []const Ref,
    lambda: *const Lambda,
    apply: Apply,
    let: *const Let,
    /// A new env of one slot holding the (thunked) scope.
    with: struct { scope: Ref, body: Ref, pos: Pos },
    /// The branches are boxed, read once the condition is known: three
    /// references and a position would make every node 40 bytes.
    @"if": struct { cond: Ref, branches: *const [2]Ref, pos: Pos },
    assert: struct { cond: Ref, body: Ref, pos: Pos },
    not: struct { e: Ref, pos: Pos },
    neg: struct { e: Ref, pos: Pos },
    binop: struct { op: BinOp, pos: Pos, a: Ref, b: Ref },
    /// The code of an import thunk: the file at this resolved path.
    import_file: []const u8,

    pub fn pos(i: *const Ir) Pos {
        return switch (i.*) {
            .constant, .local, .list, .let, .import_file => .none,
            .with_var => |v| v.pos,
            .cur_pos => |p| p,
            .concat => |c| c.pos,
            .search_path => |s| s.pos,
            .select => |s| s.pos,
            .select1 => |s| s.pos,
            .select_count => |s| s.pos,
            .has_attr => |h| h.subject.pos(),
            .attrs => |a| a.pos,
            .lambda => |l| l.pos,
            .apply => |a| a.pos,
            .with => |w| w.pos,
            .@"if" => |x| x.pos,
            .assert => |a| a.pos,
            .not => |n| n.pos,
            .neg => |n| n.pos,
            .binop => |b| b.pos,
        };
    }
};

/// `f a b`: the arguments as a pointer and a count, so the node stays 32 bytes.
pub const Apply = struct {
    func: Ref,
    args_ptr: [*]const Ref,
    nargs: u32,
    pos: Pos,

    pub fn init(func: Ref, list: []const Ref, pos: Pos) Apply {
        return .{ .func = func, .args_ptr = list.ptr, .nargs = @intCast(list.len), .pos = pos };
    }

    pub inline fn args(a: *const Apply) []const Ref {
        return a.args_ptr[0..a.nargs];
    }
};

// Every evaluated file keeps its IR for the whole run, and the node size
// decides most of it (Rust iets measured 101 MB at 32 bytes, 122 MB at 48).
comptime {
    std.debug.assert(@sizeOf(Ir) == 32);
}

pub const BinOp = enum {
    eq,
    ne,
    lt,
    ge,
    @"and",
    @"or",
    impl,
    update,
    concat_lists,
    sub,
    mul,
    div,
};

pub const AttrElem = union(enum) {
    static: Sym,
    dynamic: Ref,
};

pub const Select = struct {
    subject: Ref,
    path: []const AttrElem,
    default: ?Ref,
    pos: Pos,
};

/// Where a binding's value expression is evaluated.
pub const BindScope = enum {
    /// The set's own env (rec sets, let) or the enclosing env (plain sets).
    own,
    /// `inherit x` in a rec set or let: the enclosing env.
    outer,
    /// `inherit (e) x`: the env holding the `from` thunks.
    from,
};

pub const Bind = struct {
    sym: Sym,
    pos: Pos,
    scope: BindScope,
    value: Ref,
};

pub const DynBind = struct {
    name: Ref,
    value: Ref,
    pos: Pos,
};

pub const Attrs = struct {
    rec: bool,
    pos: Pos,
    /// Sorted by symbol id. For a rec set, slot `i` of the new env holds bind `i`.
    binds: []const Bind,
    /// The `inherit (e)` sources: slots after the binds (rec), or an env of
    /// their own (plain).
    from: []const Ref,
    dynamic: []const DynBind,
    /// Index of `__overrides` in `binds`, rec sets only.
    overrides: ?u32,
};

pub const Let = struct {
    /// A new env with `binds.len + from.len` slots, or with `base`, slots
    /// from `base` on in the env of the lambda the `let` is the body of.
    binds: []const Bind,
    from: []const Ref,
    body: Ref,
    base: u32 = own_env,

    pub const own_env = std.math.maxInt(u32);
};

pub const Formal = struct {
    sym: Sym,
    pos: Pos,
    default: ?Ref,
};

pub const Param = union(enum) {
    /// One slot.
    ident,
    /// Slot 0 is the `@` binding when `has_bind`; the formals follow, sorted by symbol.
    formals: struct { has_bind: bool, ellipsis: bool, formals: []const Formal },
};

pub const Lambda = struct {
    param: Param,
    body: Ref,
    pos: Pos,
    /// The name it is bound to, for error messages.
    name: ?Sym,
    /// The `x` in `x: e` or the `args` in `{...}@args: e`.
    arg: ?Sym,
    /// `x: e` where `e` never names `x`: no frame, the body runs in the
    /// closure's env.
    no_env: bool = false,
    /// Nonzero for the body of a lambda (`a: b: e`): its params take slots
    /// from `base` on, after the parent's, in one env.
    base: u32 = 0,
    /// Slots of the env a call evaluates the body in: `base`, the params,
    /// and a `let` body's bindings.
    frame: u32 = 0,
    /// Census only: the body reads no variable from outside the lambda.
    closed: if (census.enabled) bool else void = if (census.enabled) false else {},

    pub fn nslots(l: *const Lambda) u32 {
        return switch (l.param) {
            .ident => 1,
            .formals => |f| @as(u32, @intCast(f.formals.len)) + @intFromBool(f.has_bind),
        };
    }
};
