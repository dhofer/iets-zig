//! String context introspection (primops/context.cc): getContext,
//! appendContext, addDrvOutputDependencies, hasContext and the two
//! `unsafeDiscard*` primops.

const std = @import("std");
const Op = @import("../builtins.zig").Op;
const Evaluator = @import("../eval/Evaluator.zig");
const Error = Evaluator.Error;
const value = @import("../runtime/value.zig");
const Value = value.Value;
const Ctx = value.Ctx;
const Pos = @import("../syntax/pos.zig").Pos;
const Diag = @import("../diag.zig").Diag;
const StorePath = @import("../store/path.zig").StorePath;

pub const ops = [_]Op{
    .{ .name = "__getContext", .arity = 1, .f = getContext },
    .{ .name = "__appendContext", .arity = 2, .f = appendContext },
    .{ .name = "__addDrvOutputDependencies", .arity = 1, .f = addDrvOutputDependencies },
    .{ .name = "__hasContext", .arity = 1, .f = hasContext },
    .{ .name = "__unsafeDiscardStringContext", .arity = 1, .f = unsafeDiscardStringContext },
    .{ .name = "__unsafeDiscardOutputDependency", .arity = 1, .f = unsafeDiscardOutputDependency },
};

/// Store context elements ordered by path first, so one path's elements are adjacent.
fn byPath(_: void, a: Ctx, b: Ctx) bool {
    const o = std.mem.order(u8, a.path, b.path);
    if (o != .eq) return o == .lt;
    return a.order(b) == .lt;
}

fn getContext(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const s = try ev.forceString(args[0], pos, "while evaluating the argument passed to builtins.getContext");
    var elems: std.ArrayList(Ctx) = .empty;
    defer elems.deinit(ev.gpa);
    for (s.context()) |c| switch (c.kind) {
        .opaque_path, .drv_deep => try elems.append(ev.gpa, c),
        // primops/context.cc resolves the derived path first, which builds
        // the producer; an evaluation does not build
        .built => {
            if (std.mem.indexOfScalar(u8, c.path, '!') != null)
                return ev.fail(.unsupported, pos, "builtins.getContext cannot handle the output '{s}' of a dynamic derivation", .{c.output});
            try elems.append(ev.gpa, c);
        },
        .impure_path, .impure_meta => {},
    };
    std.sort.pdq(Ctx, elems.items, {}, byPath);
    const s_all = try ev.sym("allOutputs");
    const s_outputs = try ev.sym("outputs");
    var entries: std.ArrayList(value.Attr) = .empty;
    defer entries.deinit(ev.gpa);
    var outputs: std.ArrayList(Value) = .empty;
    defer outputs.deinit(ev.gpa);
    var i: usize = 0;
    while (i < elems.items.len) {
        const p = elems.items[i].path;
        var path = false;
        var all = false;
        outputs.clearRetainingCapacity();
        while (i < elems.items.len and std.mem.eql(u8, elems.items[i].path, p)) : (i += 1) {
            const c = elems.items[i];
            switch (c.kind) {
                .opaque_path => path = true,
                .drv_deep => all = true,
                .built => try outputs.append(ev.gpa, try ev.mkStringStatic(c.output, &.{})),
                else => unreachable,
            }
        }
        var inner: [3]value.Attr = undefined;
        var n: usize = 0;
        if (path) {
            inner[n] = .{ .sym = ev.s.path, .pos = .none, .cell = .init(.true) };
            n += 1;
        }
        if (all) {
            inner[n] = .{ .sym = s_all, .pos = .none, .cell = .init(.true) };
            n += 1;
        }
        if (outputs.items.len > 0) {
            inner[n] = .{ .sym = s_outputs, .pos = .none, .cell = .init(try ev.mkList(outputs.items)) };
            n += 1;
        }
        const v = try ev.mkAttrs(inner[0..n], pos);
        try entries.append(ev.gpa, .{ .sym = try ev.sym(p), .pos = .none, .cell = .init(v) });
    }
    return ev.mkAttrs(entries.items, pos);
}

fn appendContext(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const orig = try ev.forceString(args[0], pos, "while evaluating the first argument passed to builtins.appendContext");
    const attrs = try ev.forceAttrs(args[1], pos, "while evaluating the second argument passed to builtins.appendContext");
    const s_all = try ev.sym("allOutputs");
    const s_outputs = try ev.sym("outputs");
    var ctx: std.ArrayList(Ctx) = .empty;
    defer ctx.deinit(ev.gpa);
    try ctx.appendSlice(ev.gpa, orig.context());
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    for (attrs.attrs()) |*a| {
        const name = ev.interner.name(a.sym);
        const sp = StorePath.parse(name, &d) catch
            return ev.fail(.eval, a.pos, "context key '\"{s}\"' is not a store path", .{name});
        const v = try ev.forceAttrs(a.cell.get(), a.pos, "while evaluating the value of a string context");
        if (v.get(ev.s.path)) |pa| {
            if (try ev.forceBool(pa.cell.get(), pa.pos, "while evaluating the `path` attribute of a string context"))
                try ctx.append(ev.gpa, .{ .kind = .opaque_path, .path = name });
        }
        if (v.get(s_all)) |aa| {
            if (try ev.forceBool(aa.cell.get(), aa.pos, "while evaluating the `allOutputs` attribute of a string context")) {
                if (!sp.isDerivation())
                    return ev.fail(.eval, a.pos, "tried to add all-outputs context of \"{s}\", which is not a derivation, to a string", .{name});
                try ctx.append(ev.gpa, .{ .kind = .drv_deep, .path = name });
            }
        }
        if (v.get(s_outputs)) |oa| {
            const l = try ev.forceList(oa.cell.get(), oa.pos, "while evaluating the `outputs` attribute of a string context");
            if (l.len > 0 and !sp.isDerivation())
                return ev.fail(.eval, a.pos, "tried to add derivation output context of \"{s}\", which is not a derivation, to a string", .{name});
            for (l.cells()) |*c| {
                const output = try ev.forceStringNoCtx(c.get(), oa.pos, "while evaluating an output name within a string context");
                try ctx.append(ev.gpa, .{ .kind = .built, .path = name, .output = output });
            }
        }
    }
    return ev.mkStringStatic(orig.bytes(), try ev.ctxToArena(ctx.items));
}

fn addDrvOutputDependencies(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ev.gpa);
    var ctx: std.ArrayList(Ctx) = .empty;
    defer ctx.deinit(ev.gpa);
    try ev.coerceToString(args[0], &out, &ctx, pos, "while evaluating the argument passed to builtins.addDrvOutputDependencies", .{ .copy_to_store = false });
    var store: std.ArrayList(Ctx) = .empty;
    defer store.deinit(ev.gpa);
    for (ctx.items) |c| if (c.isStore()) try store.append(ev.gpa, c);
    const uniq = try ev.ctxToArena(store.items);
    if (uniq.len != 1)
        return ev.fail(.eval, pos, "context of string '{s}' must have exactly one element, but has {d}", .{ out.items, uniq.len });
    var c = uniq[0];
    switch (c.kind) {
        .opaque_path => {
            if (!std.mem.endsWith(u8, c.path, ".drv"))
                return ev.fail(.eval, pos, "path '{s}' is not a derivation", .{c.path});
            c.kind = .drv_deep;
        },
        .built => return ev.fail(.eval, pos, "`addDrvOutputDependencies` can only act on derivations, not on a derivation output such as '{s}'", .{c.output}),
        .drv_deep => {},
        .impure_path, .impure_meta => unreachable,
    }
    return ev.mkStringCtx(out.items, &.{c});
}

fn hasContext(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const s = try ev.forceString(args[0], pos, "while evaluating the argument passed to builtins.hasContext");
    for (s.context()) |c| if (c.isStore()) return .true;
    return .false;
}

fn unsafeDiscardStringContext(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ev.gpa);
    var ctx: std.ArrayList(Ctx) = .empty;
    defer ctx.deinit(ev.gpa);
    try ev.coerceToString(args[0], &out, &ctx, pos, "while evaluating the argument passed to builtins.unsafeDiscardStringContext", .{});
    if (ctx.items.len == 0) {
        const v = try ev.force(args[0]);
        if (v.kind() == .string) return v;
    }
    return ev.mkString(out.items);
}

fn unsafeDiscardOutputDependency(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ev.gpa);
    var ctx: std.ArrayList(Ctx) = .empty;
    defer ctx.deinit(ev.gpa);
    try ev.coerceToString(args[0], &out, &ctx, pos, "while evaluating the argument passed to builtins.unsafeDiscardOutputDependency", .{});
    for (ctx.items) |*c| if (c.kind == .drv_deep) {
        c.kind = .opaque_path;
    };
    return ev.mkStringCtx(out.items, ctx.items);
}
