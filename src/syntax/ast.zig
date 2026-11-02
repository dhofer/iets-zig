//! The shared AST. The parser produces it, `compile` consumes it. The shape
//! is deliberately raw: attrpaths are not merged, scopes are not resolved,
//! `inherit` is kept as written. Those transforms live in `compile`.
//!
//! Nodes are a `MultiArrayList` of a tagged union (tags and payloads in two
//! dense arrays) plus a parallel span array; `ExprId` indexes both. Every
//! variable-length payload (attrpaths, string parts, bindings, arguments,
//! formals, literal bytes) lives in one side table and a node holds a
//! `Range` into it, so a file is a dozen arrays, not a heap block per node.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sym = @import("symbol.zig").Sym;

/// Index of a node in `Ast.tags`, `Ast.data` and `Ast.spans`.
pub const ExprId = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn index(e: ExprId) u32 {
        return @backingInt(e);
    }

    pub fn unwrap(e: ExprId) ?ExprId {
        return if (e == .none) null else e;
    }
};

/// Index into the evaluator's file table.
pub const FileId = enum(u32) { _ };

/// Byte range in the file. Line and column are derived from a line table.
pub const Span = struct {
    start: u32 = 0,
    end: u32 = 0,
};

/// Contiguous run in one of the `Ast` side tables.
pub const Range = struct {
    start: u32 = 0,
    len: u32 = 0,

    pub const empty: Range = .{};

    pub fn end(r: Range) u32 {
        return r.start + r.len;
    }
};

/// `inline` in optimised builds only. The parser recurses once per nesting
/// level, and a debug build gives every inlined call its own stack slots:
/// its frames would outgrow the stack the deep-nesting limit is sized for.
pub const inline_release: std.builtin.CallingConvention = if (@import("builtin").mode == .debug) .auto else .@"inline";

pub const Expr = union(enum) {
    int: i64,
    float: f64,
    /// `"..."` and `''...''`, a range of `parts`. Indentation of `''`
    /// strings is already stripped; escapes are already decoded. A plain
    /// string is one `lit`.
    str: Range,
    /// `./foo`, `/abs`, `~/x`, `<nixpkgs>`, with optional interpolation.
    path: PathExpr,
    @"var": Sym,
    /// `e.a.b or d`; `default` may be `.none`.
    select: struct { subject: ExprId, path: Range, default: ExprId },
    /// `e ? a.b`
    has_attr: struct { subject: ExprId, path: Range },
    attrs: struct { rec: bool, binds: Range },
    /// A range of `ids`.
    list: Range,
    /// `x: body`.
    lambda: struct { arg: Sym, body: ExprId },
    /// `{ ... } @ x: body`; `pattern` indexes `Ast.patterns`.
    lambda_pattern: struct { pattern: u32, body: ExprId },
    /// `f a b c` is one node with `args = [a, b, c]` (a range of `ids`).
    apply: struct { func: ExprId, args: Range },
    let: struct { binds: Range, body: ExprId },
    with: struct { scope: ExprId, body: ExprId },
    @"if": struct { cond: ExprId, then: ExprId, @"else": ExprId },
    assert: struct { cond: ExprId, body: ExprId },
    unary: struct { op: UnOp, expr: ExprId },
    binary: struct { op: BinOp, lhs: ExprId, rhs: ExprId },

    pub const Tag = std.meta.Tag(Expr);
    /// The payload without its tag, which `Ast.tags` holds.
    pub const Data = std.meta.BareUnion(Expr);

    pub inline fn split(e: Expr) struct { Tag, Data } {
        return switch (e) {
            inline else => |payload, t| .{ t, @unionInit(Data, @tagName(t), payload) },
        };
    }

    pub inline fn join(t: Tag, d: Data) Expr {
        return switch (t) {
            inline else => |tt| @unionInit(Expr, @tagName(tt), @field(d, @tagName(tt))),
        };
    }
};

pub const StrPart = union(enum) {
    /// Range in `Ast.bytes`.
    lit: Range,
    interp: ExprId,
};

pub const PathKind = enum(u8) {
    /// `./x` or `../x`; parts start with `./` or `../` as written.
    relative,
    /// `/x`; parts start with `/`.
    absolute,
    /// `~/x`; parts start with `/` (the `~` is dropped).
    home,
    /// `<x>`; the text between the angle brackets.
    search,
};

pub const PathExpr = struct {
    kind: PathKind,
    /// The literal text after the kind prefix, plus interpolations.
    parts: Range,
};

/// One element of an attribute path: `a`, `"a"`, `${e}`, `"a${e}"`.
pub const AttrElem = union(enum) {
    static: Sym,
    /// Interpolated or `${}`; a string whose value must coerce to a name.
    dynamic: ExprId,
};

pub const Bind = struct {
    span: Span,
    kind: Kind,

    pub const Kind = union(enum) {
        /// `a.b.c = e;`, `path` a range of `elems`.
        value: struct { path: Range, value: ExprId },
        /// `inherit a b;` or `inherit (e) a b;`; `from` may be `.none`,
        /// `names` a range of `names`.
        inherit: struct { from: ExprId, names: Range },
    };
};

/// An `inherit` name.
pub const Name = struct {
    sym: Sym,
    span: Span,
};

/// The `{ a, b ? d, ... }` of a lambda, with its optional `@` name.
pub const Pattern = struct {
    bind: ?Sym,
    /// A range of `formals`.
    formals: Range,
    ellipsis: bool,
};

pub const Formal = struct {
    name: Sym,
    /// May be `.none`.
    default: ExprId,
    span: Span,
};

pub const UnOp = enum(u8) { not, neg };

pub const BinOp = enum(u8) { eq, ne, lt, gt, le, ge, @"and", @"or", impl, update, concat, add, sub, mul, div };

/// A construct the parser accepts but a lint may report: a `url-literal`.
pub const Note = union(enum) {
    url: ExprId,
};

/// A `# iets:` comment as written: its text after the marker, and the byte
/// range of the line it covers (after code its own line; on a line of its
/// own the next non-blank, non-comment line). The lint layer resolves the
/// names (docs/reference/lints.md).
pub const AllowComment = struct {
    text: Span,
    line: Span,
};

/// One parsed file. Owns its arrays; free with `deinit`.
pub const Ast = struct {
    file: FileId = @fromBackingInt(@intCast(0)),
    root: ExprId = .none,
    /// Node `i` is `tags[i]` with payload `data[i]`, in two plain arrays so
    /// an append is two stores.
    tags: std.ArrayList(Expr.Tag) = .empty,
    data: std.ArrayList(Expr.Data) = .empty,
    /// `spans[i]` belongs to node `i`.
    spans: std.ArrayList(Span) = .empty,
    /// List items and application arguments.
    ids: std.ArrayList(ExprId) = .empty,
    /// Attribute paths.
    elems: std.ArrayList(AttrElem) = .empty,
    /// String and path parts.
    parts: std.ArrayList(StrPart) = .empty,
    /// Decoded text of every `StrPart.lit`.
    bytes: std.ArrayList(u8) = .empty,
    binds: std.ArrayList(Bind) = .empty,
    /// `inherit` names.
    names: std.ArrayList(Name) = .empty,
    patterns: std.ArrayList(Pattern) = .empty,
    formals: std.ArrayList(Formal) = .empty,
    notes: std.ArrayList(Note) = .empty,
    allows: std.ArrayList(AllowComment) = .empty,

    pub fn deinit(a: *Ast, gpa: Allocator) void {
        a.tags.deinit(gpa);
        a.data.deinit(gpa);
        inline for (.{ "spans", "ids", "elems", "parts", "bytes", "binds", "names", "patterns", "formals", "notes", "allows" }) |f|
            @field(a, f).deinit(gpa);
        a.* = undefined;
    }

    /// Forget the contents but keep the buffers for the next file.
    pub fn clear(a: *Ast) void {
        a.tags.clearRetainingCapacity();
        a.data.clearRetainingCapacity();
        inline for (.{ "spans", "ids", "elems", "parts", "bytes", "binds", "names", "patterns", "formals", "notes", "allows" }) |f|
            @field(a, f).clearRetainingCapacity();
        a.root = .none;
    }

    pub fn len(a: *const Ast) u32 {
        return @intCast(a.tags.items.len);
    }

    pub inline fn expr(a: *const Ast, id: ExprId) Expr {
        return .join(a.tags.items[id.index()], a.data.items[id.index()]);
    }

    pub inline fn tag(a: *const Ast, id: ExprId) Expr.Tag {
        return a.tags.items[id.index()];
    }

    /// Inline, so the tag of `e` is known at each call and the split is
    /// two plain stores.
    pub fn add(a: *Ast, gpa: Allocator, e: Expr, sp: Span) callconv(inline_release) Allocator.Error!ExprId {
        const n = a.tags.items.len;
        if (n == a.tags.capacity or n == a.data.capacity or n == a.spans.capacity) try a.grow(gpa);
        const t, const d = e.split();
        a.tags.appendAssumeCapacity(t);
        a.data.appendAssumeCapacity(d);
        a.spans.appendAssumeCapacity(sp);
        return @fromBackingInt(@intCast(n));
    }

    noinline fn grow(a: *Ast, gpa: Allocator) Allocator.Error!void {
        const n = @max(a.tags.items.len * 2, 64);
        try a.ensureCapacity(gpa, n);
    }

    /// Replace node `id`, keeping its span.
    pub fn set(a: *Ast, id: ExprId, e: Expr) void {
        a.tags.items[id.index()], a.data.items[id.index()] = e.split();
    }

    pub fn ensureCapacity(a: *Ast, gpa: Allocator, n: usize) Allocator.Error!void {
        try a.tags.ensureTotalCapacity(gpa, n);
        try a.data.ensureTotalCapacity(gpa, n);
        try a.spans.ensureTotalCapacity(gpa, n);
    }

    pub inline fn span(a: *const Ast, id: ExprId) Span {
        return a.spans.items[id.index()];
    }

    pub inline fn idsOf(a: *const Ast, r: Range) []const ExprId {
        return a.ids.items[r.start..r.end()];
    }

    pub inline fn elemsOf(a: *const Ast, r: Range) []const AttrElem {
        return a.elems.items[r.start..r.end()];
    }

    pub inline fn partsOf(a: *const Ast, r: Range) []const StrPart {
        return a.parts.items[r.start..r.end()];
    }

    pub inline fn bytesOf(a: *const Ast, r: Range) []const u8 {
        return a.bytes.items[r.start..r.end()];
    }

    pub inline fn bindsOf(a: *const Ast, r: Range) []const Bind {
        return a.binds.items[r.start..r.end()];
    }

    pub inline fn namesOf(a: *const Ast, r: Range) []const Name {
        return a.names.items[r.start..r.end()];
    }

    pub inline fn formalsOf(a: *const Ast, r: Range) []const Formal {
        return a.formals.items[r.start..r.end()];
    }

    pub inline fn pattern(a: *const Ast, i: u32) Pattern {
        return a.patterns.items[i];
    }

    /// The text of a string that is exactly one literal part.
    pub fn singleLit(a: *const Ast, parts: Range) ?[]const u8 {
        const ps = a.partsOf(parts);
        if (ps.len != 1) return null;
        return switch (ps[0]) {
            .lit => |l| a.bytesOf(l),
            .interp => null,
        };
    }
};

test "payloads stay small" {
    // the bare union of a `MultiArrayList` is as large as the largest
    inline for (@typeInfo(Expr).@"union".field_types) |t| try std.testing.expect(@sizeOf(t) <= 16);
}
