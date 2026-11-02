//! Attribute set primops.

const std = @import("std");
const Bits = @import("Bits.zig");
const Op = @import("../builtins.zig").Op;
const Evaluator = @import("../eval/Evaluator.zig");
const Error = Evaluator.Error;
const value = @import("../runtime/value.zig");
const Value = value.Value;
const Attr = value.Attr;
const Pos = @import("../syntax/pos.zig").Pos;
const lint = @import("../lint.zig");
const Sym = @import("../syntax/symbol.zig").Sym;
const print = @import("../eval/print.zig");

pub const ops = [_]Op{
    .{ .name = "__attrNames", .arity = 1, .f = attrNames },
    .{ .name = "__attrValues", .arity = 1, .f = attrValues },
    .{ .name = "__getAttr", .arity = 2, .f = getAttr },
    .{ .name = "__hasAttr", .arity = 2, .f = hasAttr },
    .{ .name = "removeAttrs", .arity = 2, .f = removeAttrs },
    .{ .name = "__intersectAttrs", .arity = 2, .f = intersectAttrs },
    .{ .name = "__mapAttrs", .arity = 2, .f = mapAttrs },
    .{ .name = "__listToAttrs", .arity = 1, .f = listToAttrs },
    .{ .name = "__zipAttrsWith", .arity = 2, .f = zipAttrsWith },
    .{ .name = "__catAttrs", .arity = 2, .f = catAttrs },
    .{ .name = "__groupBy", .arity = 2, .f = groupBy },
};

fn symLess(_: void, a: Sym, b: Sym) bool {
    return @backingInt(a) < @backingInt(b);
}

fn attrLess(_: void, a: Attr, b: Attr) bool {
    return symLess({}, a.sym, b.sym);
}

/// The suspended `f name v`, as two nested applications.
fn thunkApp2(ev: *Evaluator, f: Value, name: Sym, v: Value) Error!Value {
    return ev.mkThunkApp(try ev.mkThunkApp(f, try ev.symString(name)), v);
}

fn attrNames(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const a = try ev.forceAttrs(args[0], pos, "while evaluating the argument passed to builtins.attrNames");
    const sorted = try print.lexicographic(ev, a);
    defer ev.gpa.free(sorted);
    const l = try ev.allocList(sorted.len);
    for (l.raw(), sorted) |*c, at| c.* = .init(try ev.symString(at.sym));
    return .fromPtr(.ptr, l);
}

fn attrValues(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const a = try ev.forceAttrs(args[0], pos, "while evaluating the argument passed to builtins.attrValues");
    const sorted = try print.lexicographic(ev, a);
    defer ev.gpa.free(sorted);
    const l = try ev.allocList(sorted.len);
    for (l.raw(), sorted) |*c, at| c.* = .init(at.cell.get());
    return .fromPtr(.ptr, l);
}

fn getAttr(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const s = try ev.forceSym(args[0], pos, "while evaluating the first argument passed to builtins.getAttr");
    const a = try ev.forceSet(args[1], pos, "while evaluating the second argument passed to builtins.getAttr");
    const at = Evaluator.getAttr(a, s) orelse return ev.fail(.missing_attr, pos, "attribute '{s}' missing", .{ev.interner.name(s)});
    // a tree's lazy `revCount` is a thunk application: the name is looked
    // at only then (`purity.countRead`)
    if (at.cell.get().tag() == .thunk_app) if (s == ev.s.revCount) return lint.purity.countRead(ev, &at.cell, pos);
    return ev.forceCell(&at.cell);
}

fn hasAttr(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const s = try ev.forceSym(args[0], pos, "while evaluating the first argument passed to builtins.hasAttr");
    const a = try ev.forceSet(args[1], pos, "while evaluating the second argument passed to builtins.hasAttr");
    return .fromBool(Evaluator.getAttr(a, s) != null);
}

fn removeAttrs(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const a = try ev.forceAttrs(args[0], pos, "while evaluating the first argument passed to builtins.removeAttrs");
    const l = try ev.forceList(args[1], pos, "while evaluating the second argument passed to builtins.removeAttrs");
    // Each name is looked up in the sorted set and its entry marked, where
    // sorting the names took half the time on long lists.
    const src = a.attrs();
    var marks: Bits = try .init(ev.gpa, src.len);
    defer marks.deinit(ev.gpa);
    var removed: usize = 0;
    for (l.cells()) |*c| {
        const name = try ev.forceSym(c.get(), pos, "while evaluating the values of the second argument passed to builtins.removeAttrs");
        const at = a.get(name) orelse continue;
        const i = at - src.ptr;
        if (marks.isSet(i)) continue;
        marks.set(i);
        removed += 1;
    }
    // Nothing removed: the same entries, so the same set.
    if (removed == 0) return .fromPtr(.ptr, a);
    const out = try ev.allocAttrs(src.len - removed);
    ev.censusOrigin(out, .remove_attrs);
    const items = out.raw();
    var n: usize = 0;
    for (src, 0..) |at, i| {
        if (marks.isSet(i)) continue;
        items[n] = at;
        n += 1;
    }
    return .fromPtr(.ptr, out);
}

fn intersectAttrs(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const left = try ev.forceSet(args[0], pos, "while evaluating the first argument passed to builtins.intersectAttrs");
    const right = try ev.forceSet(args[1], pos, "while evaluating the second argument passed to builtins.intersectAttrs");
    // Walk the smaller side and probe the other, which stays a union if it
    // is one: `callPackage` intersects a few formals with all of `pkgs`.
    const left_small = sizeHint(left) < sizeHint(right);
    const small = (if (left_small) left else right).as(value.Attrs);
    const big = if (left_small) right else left;
    // The small side is usually a function's formals: the result fits on
    // the stack, and the arena gets one copy at its size.
    var stack: [64]Attr = undefined;
    var heap: std.ArrayList(Attr) = .empty;
    defer heap.deinit(ev.gpa);
    const out = if (small.len <= stack.len) stack[0..small.len] else try heap.addManyAsSlice(ev.gpa, small.len);
    var n: usize = 0;
    for (small.attrs()) |*k| {
        const b = Evaluator.getAttr(big, k.sym) orelse continue;
        // The value is always the right side's.
        out[n] = if (left_small) b.* else k.*;
        n += 1;
    }
    return ev.mkAttrsSortedAs(out[0..n], .intersect);
}

/// A set's size, or a union's upper bound, without flattening it.
fn sizeHint(v: Value) usize {
    const u = v.asUnion() orelse return v.as(value.Attrs).len;
    if (u.flat_cache.load(.acquire)) |f| return f.len;
    var n: usize = 0;
    for (u.leaves()) |l| n += l.len;
    return n;
}

fn mapAttrs(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const a = try ev.forceAttrs(args[1], pos, "while evaluating the second argument passed to builtins.mapAttrs");
    return ev.mapAttrs(args[0], a);
}

fn listToAttrs(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const l = try ev.forceList(args[0], pos, "while evaluating the argument passed to builtins.listToAttrs");
    ev.offerList(l);
    var entries: std.ArrayList(Attr) = .empty;
    defer entries.deinit(ev.gpa);
    var seen: std.AutoHashMapUnmanaged(Sym, void) = .empty;
    defer seen.deinit(ev.gpa);
    for (l.cells()) |*c| {
        const a = try ev.forceAttrs(c.get(), pos, "while evaluating an element of the list passed to builtins.listToAttrs");
        const n = a.get(ev.s.name) orelse
            return ev.fail(.type, pos, "attribute 'name' missing in a {{name=...; value=...;}} pair", .{});
        const s = try ev.forceSym(n.cell.get(), n.pos, "while evaluating the `name` attribute of an element of the list passed to builtins.listToAttrs");
        // The first pair with a name wins, and a later one needs no value.
        if ((try seen.getOrPut(ev.gpa, s)).found_existing) continue;
        const v = a.get(ev.s.value) orelse
            return ev.fail(.type, pos, "attribute 'value' missing in a {{name=...; value=...;}} pair", .{});
        try entries.append(ev.gpa, .{ .sym = s, .pos = v.pos, .cell = .init(v.cell.get()) });
    }
    std.sort.pdq(Attr, entries.items, {}, attrLess);
    return ev.mkAttrsSortedAs(entries.items, .list_to_attrs);
}

/// Values collected per name.
const Groups = struct {
    map: std.AutoArrayHashMapUnmanaged(Sym, std.ArrayList(Value)) = .empty,

    fn add(g: *Groups, gpa: std.mem.Allocator, s: Sym, v: Value) Error!void {
        const e = try g.map.getOrPut(gpa, s);
        if (!e.found_existing) e.value_ptr.* = .empty;
        try e.value_ptr.append(gpa, v);
    }

    fn deinit(g: *Groups, gpa: std.mem.Allocator) void {
        for (g.map.values()) |*l| l.deinit(gpa);
        g.map.deinit(gpa);
    }

    /// A set of the groups as lists, or of the suspended `f name list` when given `f`.
    fn toAttrs(g: *Groups, ev: *Evaluator, f: ?Value) Error!Value {
        const out = try ev.allocAttrs(g.map.count());
        if (f != null) ev.censusOrigin(out, .zip_attrs_with);
        for (out.raw(), g.map.keys(), g.map.values()) |*o, s, vals| {
            const list = try ev.mkList(vals.items);
            const v = if (f) |func| try thunkApp2(ev, func, s, list) else list;
            o.* = .{ .sym = s, .pos = .none, .cell = .init(v) };
        }
        std.sort.pdq(Attr, out.raw(), {}, attrLess);
        return .fromPtr(.ptr, out);
    }
};

fn zipAttrsWith(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const f = try ev.forceFunction(args[0], pos, "while evaluating the first argument passed to builtins.zipAttrsWith");
    const l = try ev.forceList(args[1], pos, "while evaluating the second argument passed to builtins.zipAttrsWith");
    ev.offerList(l);
    var groups: Groups = .{};
    defer groups.deinit(ev.gpa);
    for (l.cells()) |*c| {
        const a = try ev.forceAttrs(c.get(), .none, "while evaluating a value of the list passed as second argument to builtins.zipAttrsWith");
        for (a.attrs()) |at| try groups.add(ev.gpa, at.sym, at.cell.get());
    }
    return groups.toAttrs(ev, f);
}

fn catAttrs(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const s = try ev.forceSym(args[0], pos, "while evaluating the first argument passed to builtins.catAttrs");
    const l = try ev.forceList(args[1], pos, "while evaluating the second argument passed to builtins.catAttrs");
    ev.offerList(l);
    var out: std.ArrayList(Value) = .empty;
    defer out.deinit(ev.gpa);
    for (l.cells()) |*c| {
        // A lookup probes a union's leaves: no flat copy.
        const a = try ev.forceSet(c.get(), pos, "while evaluating an element in the list passed as second argument to builtins.catAttrs");
        if (Evaluator.getAttr(a, s)) |at| try out.append(ev.gpa, at.cell.get());
    }
    return ev.mkList(out.items);
}

fn groupBy(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const f = try ev.forceFunction(args[0], pos, "while evaluating the first argument passed to builtins.groupBy");
    const l = try ev.forceList(args[1], pos, "while evaluating the second argument passed to builtins.groupBy");
    ev.offerList(l);
    var groups: Groups = .{};
    defer groups.deinit(ev.gpa);
    for (l.cells()) |*c| {
        const elem = c.get();
        const r = try ev.call1(f, elem, pos);
        const s = try ev.forceSym(r, pos, "while evaluating the return value of the grouping function passed to builtins.groupBy");
        try groups.add(ev.gpa, s, elem);
    }
    return groups.toAttrs(ev, null);
}
