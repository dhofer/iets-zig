//! The typed value handle an embedder works with.
//!
//! `Eval` wraps an `Evaluator`; `Value` is a value that evaluator holds.
//! Zig has no lifetimes, so nothing stops a `Value` from outliving its
//! evaluator: keep one only while the evaluator lives, and pass it back only
//! to the `Eval` it came from (docs/reference/library.md, "The value API").
//! Nothing here exposes the runtime's word, an arena pointer or a tag.
//!
//! The layer is thin: every getter is the load the evaluator itself does.
//! Only the constructors allocate.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Evaluator = @import("../eval/Evaluator.zig");
const import_ = @import("../eval/import.zig");
const rt = @import("../runtime/value.zig");
const api = @import("../api.zig");

const Error = Evaluator.Error;
const where = "while reading a value through the library API";

/// The type of a value, as Nix sees it. `thunk` is the one mutable state:
/// it becomes one of the others once forced.
pub const ValueKind = enum {
    thunk,
    int,
    float,
    bool,
    string,
    path,
    null,
    attrs,
    list,
    function,

    /// The name `builtins.typeOf` gives; `"thunk"` has no Nix name.
    pub fn typeOf(k: ValueKind) []const u8 {
        return switch (k) {
            .attrs => "set",
            .function => "lambda",
            else => @tagName(k),
        };
    }
};

/// One element of a string's context.
pub const ContextElem = union(enum) {
    /// A store path referenced as-is.
    opaque_path: []const u8,
    /// `=drv`: the whole derivation closure.
    drv_deep: []const u8,
    /// `!out!drv`: one output of a derivation.
    built: struct { drv: []const u8, output: []const u8 },
    /// An absolute path outside the store that a coercion kept as text, or
    /// the name of source tree metadata (`self.rev`). Invisible to
    /// `builtins.getContext`.
    impure: []const u8,

    /// The path the element names: the store path, the derivation, or the
    /// impure path or name.
    pub fn path(c: ContextElem) []const u8 {
        return switch (c) {
            .opaque_path, .drv_deep, .impure => |p| p,
            .built => |b| b.drv,
        };
    }
};

/// A string's context, in its order.
pub const Context = struct {
    items: []const rt.Ctx,
    i: usize = 0,

    pub fn len(c: Context) usize {
        return c.items.len;
    }

    pub fn next(c: *Context) ?ContextElem {
        if (c.i >= c.items.len) return null;
        const x = c.items[c.i];
        c.i += 1;
        return switch (x.kind) {
            .opaque_path => .{ .opaque_path = x.path },
            .drv_deep => .{ .drv_deep = x.path },
            .built => .{ .built = .{ .drv = x.path, .output = x.output } },
            .impure_path, .impure_meta => .{ .impure = x.path },
        };
    }
};

/// A value of the evaluator an `Eval` wraps: one machine word.
pub const Value = extern struct {
    w: rt.Value,

    /// The forced view, or null while the value is still a thunk.
    inline fn view(v: Value) ?rt.View {
        if (v.w.isThunk()) return null;
        if (v.w.tag() == .imm) switch (v.w) {
            .null, .true, .false => {},
            else => return null,
        };
        return v.w.view();
    }

    pub fn kind(v: Value) ValueKind {
        const x = v.view() orelse return .thunk;
        return switch (x) {
            .int => .int,
            .float => .float,
            .bool => .bool,
            .null => .null,
            .string => .string,
            .path => .path,
            .list => .list,
            .attrs => .attrs,
            .lambda, .primop, .primop_app => .function,
            .thunk => .thunk,
        };
    }

    pub fn asInt(v: Value) ?i64 {
        return switch (v.view() orelse return null) {
            .int => |i| i,
            else => null,
        };
    }

    /// The value as a float; an integer widens, as `forceFloat` does.
    pub fn asFloat(v: Value) ?f64 {
        return switch (v.view() orelse return null) {
            .float => |f| f,
            .int => |i| @floatFromInt(i),
            else => null,
        };
    }

    pub fn asBool(v: Value) ?bool {
        return switch (v.view() orelse return null) {
            .bool => |b| b,
            else => null,
        };
    }

    pub fn isNull(v: Value) bool {
        return v.w == .null;
    }

    /// The bytes of a string, borrowed from the arena. Nix strings are
    /// arbitrary bytes, not necessarily UTF-8.
    pub fn asBytes(v: Value) ?[]const u8 {
        return switch (v.view() orelse return null) {
            .string => |s| s.bytes(),
            else => null,
        };
    }

    /// The string's context, empty for every other type.
    pub fn context(v: Value) Context {
        const x = v.view() orelse return .{ .items = &.{} };
        return switch (x) {
            .string => |s| .{ .items = s.context() },
            else => .{ .items = &.{} },
        };
    }

    pub fn asPath(v: Value) ?[]const u8 {
        return switch (v.view() orelse return null) {
            .path => |p| p.bytes(),
            else => null,
        };
    }

    pub fn listLen(v: Value) ?usize {
        return switch (v.view() orelse return null) {
            .list => |l| l.len,
            else => null,
        };
    }

    /// Element `i`, unforced.
    pub fn listGet(v: Value, i: usize) ?Value {
        return switch (v.view() orelse return null) {
            .list => |l| if (i < l.len) .{ .w = l.cells()[i].get() } else null,
            else => null,
        };
    }

    /// The number of attributes. The result of `//` is counted over its
    /// sides, without the flat copy `Eval.attrAt` makes.
    pub fn attrsLen(v: Value) ?usize {
        if (v.view() == null or v.w.kind() != .attrs) return null;
        const u = v.w.asUnion() orelse return v.w.as(rt.Attrs).len;
        if (u.flat_cache.load(.acquire)) |f| return f.len;
        // a name counts in the last side that has it
        const ls = u.leaves();
        var n: usize = 0;
        for (ls, 0..) |l, i| for (l.attrs()) |a| {
            for (ls[i + 1 ..]) |later| {
                if (later.get(a.sym) != null) break;
            } else n += 1;
        };
        return n;
    }
};

/// An evaluator, wrapped for the values it hands out. Every operation that
/// may evaluate, intern a name or allocate goes through it. Keep one `Eval`
/// per evaluator: a value passed to another reads names through the wrong
/// symbol table.
pub const Eval = struct {
    ev: *Evaluator,

    pub fn init(ev: *Evaluator) Eval {
        return .{ .ev = ev };
    }

    /// The evaluator itself, for the parts of the library that take one.
    pub fn evaluator(e: Eval) *Evaluator {
        return e.ev;
    }

    /// Evaluate an expression; relative paths resolve against `base_dir`.
    pub fn evalExpr(e: Eval, src: []const u8, base_dir: []const u8) Error!Value {
        const code = try import_.compileSource(e.ev, "«string»", src, base_dir, null);
        return .{ .w = try e.ev.eval(e.ev.root_env, code) };
    }

    /// Evaluate what `args` names: an expression, a file or a flake output.
    /// `a` holds the paths made absolute against `cwd`.
    pub fn evaluate(e: Eval, a: Allocator, args: *const api.EvalArgs, cwd: []const u8) Error!Value {
        return .{ .w = try api.evaluate(e.ev, a, args, cwd) };
    }

    /// To weak head normal form: the value's own type becomes known.
    pub fn force(e: Eval, v: Value) Error!Value {
        return .{ .w = try e.ev.force(v.w) };
    }

    /// Recursively, through lists and attribute sets.
    pub fn forceDeep(e: Eval, v: Value) Error!Value {
        return .{ .w = try e.ev.forceDeep(v.w) };
    }

    /// The attribute `name`, unforced, or null when the set has none.
    /// Fails when `v` is not an attribute set.
    pub fn attr(e: Eval, v: Value, name: []const u8) Error!?Value {
        const set = try e.ev.forceSet(v.w, .none, where);
        // a name no source ever mentioned cannot be an attribute
        const sym = e.ev.interner.get(name) orelse return null;
        const at = Evaluator.getAttr(set, sym) orelse return null;
        return .{ .w = at.cell.get() };
    }

    pub fn hasAttr(e: Eval, v: Value, name: []const u8) Error!bool {
        return (try e.attr(v, name)) != null;
    }

    pub const Entry = struct { name: []const u8, value: Value };

    /// Attribute `i` in the set's own order: its name and its unforced
    /// value. The order is not alphabetical (docs/reference/library.md). On
    /// the result of `//` the first call makes the flat copy, once.
    pub fn attrAt(e: Eval, v: Value, i: usize) Error!?Entry {
        const a = try e.ev.forceAttrs(v.w, .none, where);
        if (i >= a.len) return null;
        const at = &a.attrs()[i];
        return .{ .name = e.ev.interner.name(at.sym), .value = .{ .w = at.cell.get() } };
    }

    /// Apply a function value to one argument.
    pub fn call(e: Eval, f: Value, arg: Value) Error!Value {
        return .{ .w = try e.ev.call1(f.w, arg.w, .none) };
    }

    /// The same application as a thunk: nothing runs until it is forced.
    pub fn apply(e: Eval, f: Value, arg: Value) Error!Value {
        return .{ .w = try e.ev.mkThunkApp(f.w, arg.w) };
    }

    pub fn int(e: Eval, i: i64) Error!Value {
        return .{ .w = try e.ev.mkInt(i) };
    }

    pub fn float(e: Eval, f: f64) Error!Value {
        return .{ .w = try e.ev.mkFloat(f) };
    }

    pub fn boolean(_: Eval, b: bool) Value {
        return .{ .w = .fromBool(b) };
    }

    pub fn nullValue(_: Eval) Value {
        return .{ .w = .null };
    }

    /// A string without context; the bytes are copied into the arena.
    pub fn string(e: Eval, bytes: []const u8) Error!Value {
        return .{ .w = try e.ev.mkString(bytes) };
    }

    /// A path; the bytes are copied into the arena.
    pub fn path(e: Eval, p: []const u8) Error!Value {
        return .{ .w = try e.ev.mkPath(p) };
    }

    /// A list; the elements are copied.
    pub fn list(e: Eval, items: []const Value) Error!Value {
        // `Value` is the word it wraps
        return .{ .w = try e.ev.mkList(@ptrCast(items)) };
    }

    /// An attribute set. Fails on a repeated name. The entries are gathered
    /// into a temporary before the copy.
    pub fn attrs(e: Eval, entries: []const Entry) Error!Value {
        const es = try e.ev.gpa.alloc(rt.Attr, entries.len);
        defer e.ev.gpa.free(es);
        for (entries, es) |x, *o| o.* = .{ .sym = try e.ev.sym(x.name), .pos = .none, .cell = .init(x.value.w) };
        return .{ .w = try e.ev.mkAttrs(es, .none) };
    }
};

comptime {
    std.debug.assert(@sizeOf(Value) == @sizeOf(rt.Value));
}

const testing = std.testing;

/// `src` evaluated in a fresh evaluator, handed to `f`.
fn withEval(src: []const u8, ctx: anytype, comptime f: fn (@TypeOf(ctx), Eval, Value) anyerror!void) !void {
    const inst = try api.Instance.create(testing.allocator, testing.io, .{});
    defer inst.destroy();
    const e: Eval = .init(&inst.ev);
    try f(ctx, e, try e.evalExpr(src, "/"));
}

test "scalars" {
    try withEval("1", {}, struct {
        fn f(_: void, e: Eval, v0: Value) !void {
            const v = try e.force(v0);
            try testing.expectEqual(ValueKind.int, v.kind());
            try testing.expectEqual(@as(?i64, 1), v.asInt());
            try testing.expectEqual(@as(?f64, 1.0), v.asFloat());
            try testing.expectEqual(@as(?bool, null), v.asBool());
        }
    }.f);
    try withEval("1.5", {}, struct {
        fn f(_: void, e: Eval, v: Value) !void {
            try testing.expectEqual(@as(?f64, 1.5), (try e.force(v)).asFloat());
        }
    }.f);
    try withEval("true", {}, struct {
        fn f(_: void, e: Eval, v: Value) !void {
            try testing.expectEqual(@as(?bool, true), (try e.force(v)).asBool());
        }
    }.f);
    try withEval("null", {}, struct {
        fn f(_: void, e: Eval, v: Value) !void {
            try testing.expect((try e.force(v)).isNull());
        }
    }.f);
    try withEval("/a/b", {}, struct {
        fn f(_: void, e: Eval, v0: Value) !void {
            const v = try e.force(v0);
            try testing.expectEqual(ValueKind.path, v.kind());
            try testing.expectEqualStrings("/a/b", v.asPath().?);
        }
    }.f);
    for ([_][]const u8{ "x: x", "builtins.add" }) |src| try withEval(src, {}, struct {
        fn f(_: void, e: Eval, v: Value) !void {
            try testing.expectEqual(ValueKind.function, (try e.force(v)).kind());
        }
    }.f);
}

test "a getter on an unforced value reads nothing; it reports thunk" {
    try withEval("{ a = (z: z + 1) 1; }", {}, struct {
        fn f(_: void, e: Eval, v: Value) !void {
            const a = (try e.attr(v, "a")).?;
            try testing.expectEqual(ValueKind.thunk, a.kind());
            try testing.expectEqual(@as(?i64, null), a.asInt());
            try testing.expectEqual(@as(?usize, null), a.attrsLen());
            try testing.expect(!a.isNull());
            try testing.expectEqual(@as(?i64, 2), (try e.force(a)).asInt());
        }
    }.f);
}

test "strings and context" {
    try withEval("\"hi\"", {}, struct {
        fn f(_: void, e: Eval, v0: Value) !void {
            const v = try e.force(v0);
            try testing.expectEqualStrings("hi", v.asBytes().?);
            try testing.expectEqual(@as(usize, 0), v.context().len());
        }
    }.f);
    const p = "/nix/store/00000000000000000000000000000000-foo";
    try withEval("builtins.appendContext \"x\" { \"" ++ p ++ "\" = { path = true; }; }", {}, struct {
        fn f(_: void, e: Eval, v0: Value) !void {
            const v = try e.force(v0);
            try testing.expectEqualStrings("x", v.asBytes().?);
            var ctx = v.context();
            try testing.expectEqual(@as(usize, 1), ctx.len());
            try testing.expectEqualDeep(ContextElem{ .opaque_path = p }, ctx.next().?);
            try testing.expect(ctx.next() == null);
        }
    }.f);
    try withEval("toString ./a", {}, struct {
        fn f(_: void, e: Eval, v0: Value) !void {
            const v = try e.force(v0);
            var ctx = v.context();
            try testing.expectEqualDeep(ContextElem{ .impure = "/a" }, ctx.next().?);
        }
    }.f);
}

test "lists" {
    try withEval("[ 1 2 3 ]", {}, struct {
        fn f(_: void, e: Eval, v0: Value) !void {
            const v = try e.force(v0);
            try testing.expectEqual(@as(?usize, 3), v.listLen());
            try testing.expectEqual(@as(?usize, null), v.attrsLen());
            try testing.expectEqual(@as(?i64, 2), (try e.force(v.listGet(1).?)).asInt());
            try testing.expect(v.listGet(3) == null);
        }
    }.f);
}

fn sortedNames(e: Eval, v: Value, out: *[2][]const u8) !void {
    for (out, 0..) |*n, i| n.* = (try e.attrAt(v, i)).?.name;
    std.mem.sort([]const u8, out, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
}

test "attributes by name and by index" {
    try withEval("{ b = 2; a = 1; }", {}, struct {
        fn f(_: void, e: Eval, v0: Value) !void {
            const v = try e.force(v0);
            try testing.expectEqual(@as(?usize, 2), v.attrsLen());
            try testing.expectEqual(@as(?i64, 1), (try e.force((try e.attr(v, "a")).?)).asInt());
            try testing.expect(try e.hasAttr(v, "b"));
            // index order is the evaluator's, as in nix_get_attr_byidx
            var names: [2][]const u8 = undefined;
            try sortedNames(e, v, &names);
            try testing.expectEqualStrings("a", names[0]);
            try testing.expectEqualStrings("b", names[1]);
            for (0..2) |i| {
                const at = (try e.attrAt(v, i)).?;
                const want: i64 = if (std.mem.eql(u8, at.name, "a")) 1 else 2;
                try testing.expectEqual(@as(?i64, want), (try e.force(at.value)).asInt());
            }
            try testing.expect((try e.attrAt(v, 2)) == null);
        }
    }.f);
}

test "a name the evaluation never saw is a miss, not an error" {
    try withEval("{ a = 1; }", {}, struct {
        fn f(_: void, e: Eval, v0: Value) !void {
            const v = try e.force(v0);
            try testing.expect((try e.attr(v, "nope")) == null);
            try testing.expect(!try e.hasAttr(v, "nope"));
        }
    }.f);
    try withEval("{ a = 1; c0 = 0; c1 = 0; c2 = 0; c3 = 0; c4 = 0; c5 = 0; c6 = 0; c7 = 0; } // { b = 2; a = 3; }", {}, struct {
        fn f(_: void, e: Eval, v0: Value) !void {
            const v = try e.force(v0);
            try testing.expectEqual(@as(?usize, 10), v.attrsLen());
            try testing.expect((try e.attr(v, "c")) == null);
            try testing.expectEqual(@as(?i64, 3), (try e.force((try e.attr(v, "a")).?)).asInt());
        }
    }.f);
    try withEval("{ a = 1; } // { b = 2; }", {}, struct {
        fn f(_: void, e: Eval, v0: Value) !void {
            const v = try e.force(v0);
            try testing.expectEqual(@as(?usize, 2), v.attrsLen());
            try testing.expect((try e.attr(v, "c")) == null);
            var names: [2][]const u8 = undefined;
            try sortedNames(e, v, &names);
            try testing.expectEqualStrings("a", names[0]);
            try testing.expectEqualStrings("b", names[1]);
        }
    }.f);
}

test "the wrong type is an error" {
    try withEval("1", {}, struct {
        fn f(_: void, e: Eval, v0: Value) !void {
            const v = try e.force(v0);
            try testing.expectError(error.EvalFailed, e.attr(v, "a"));
            const msg = e.ev.failure.?.msg;
            try testing.expect(std.mem.indexOf(u8, msg, "expected a set") != null);
        }
    }.f);
}

test "calling a function" {
    try withEval("x: x + 1", {}, struct {
        fn f(_: void, e: Eval, v: Value) !void {
            const r = try e.call(try e.force(v), try e.int(41));
            try testing.expectEqual(@as(?i64, 42), (try e.force(r)).asInt());
        }
    }.f);
    try withEval("s: s.name", {}, struct {
        fn f(_: void, e: Eval, v: Value) !void {
            const arg = try e.attrs(&.{.{ .name = "name", .value = try e.string("hi") }});
            const r = try e.call(try e.force(v), arg);
            try testing.expectEqualStrings("hi", (try e.force(r)).asBytes().?);
        }
    }.f);
}

test "construction" {
    try withEval("builtins.typeOf", {}, struct {
        fn f(_: void, e: Eval, v: Value) !void {
            const typeOf = try e.force(v);
            const cases = [_]struct { Value, []const u8 }{
                .{ try e.int(1), "int" },
                .{ try e.float(1.0), "float" },
                .{ e.boolean(true), "bool" },
                .{ e.nullValue(), "null" },
                .{ try e.string("s"), "string" },
                .{ try e.path("/a"), "path" },
            };
            for (cases) |c| {
                try testing.expectEqualStrings(c[1], c[0].kind().typeOf());
                const r = try e.call(typeOf, c[0]);
                try testing.expectEqualStrings(c[1], (try e.force(r)).asBytes().?);
            }
            const one = try e.int(1);
            try testing.expectEqual(@as(?usize, 2), (try e.list(&.{ one, one })).listLen());
            try testing.expectEqual(@as(?usize, 1), (try e.attrs(&.{.{ .name = "x", .value = one }})).attrsLen());
            try testing.expectError(error.EvalFailed, e.attrs(&.{ .{ .name = "x", .value = one }, .{ .name = "x", .value = one } }));
        }
    }.f);
}

test "apply defers the call; force is what runs it" {
    try withEval("x: x + 1", {}, struct {
        fn f(_: void, e: Eval, v: Value) !void {
            const t = try e.apply(try e.force(v), try e.int(41));
            try testing.expectEqual(ValueKind.thunk, t.kind());
            try testing.expectEqual(@as(?i64, 42), (try e.force(t)).asInt());
        }
    }.f);
}

test "forceDeep forces the whole tree" {
    try withEval("{ a = [ (1 + 1) ]; }", {}, struct {
        fn f(_: void, e: Eval, v0: Value) !void {
            const v = try e.forceDeep(v0);
            const a = (try e.attr(v, "a")).?;
            try testing.expectEqual(@as(?i64, 2), a.listGet(0).?.asInt());
        }
    }.f);
}
