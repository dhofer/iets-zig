//! Import, types, control flow, errors, tracing and introspection.

const std = @import("std");
const Op = @import("../builtins.zig").Op;
const Evaluator = @import("../eval/Evaluator.zig");
const Error = Evaluator.Error;
const value = @import("../runtime/value.zig");
const Value = value.Value;
const Ctx = value.Ctx;
const Pos = @import("../syntax/pos.zig").Pos;
const import_ = @import("../eval/import.zig");
const print = @import("../eval/print.zig");

pub const ops = [_]Op{
    .{ .name = "import", .arity = 1, .f = import },
    .{ .name = "scopedImport", .arity = 2, .f = scopedImport },
    .{ .name = "toString", .arity = 1, .f = toString },
    .{ .name = "__typeOf", .arity = 1, .f = typeOf },
    .{ .name = "isNull", .arity = 1, .f = isType(&.{.null}) },
    .{ .name = "__isFunction", .arity = 1, .f = isType(&.{.lambda}) },
    .{ .name = "__isInt", .arity = 1, .f = isType(&.{.int}) },
    .{ .name = "__isFloat", .arity = 1, .f = isType(&.{.float}) },
    .{ .name = "__isString", .arity = 1, .f = isType(&.{.string}) },
    .{ .name = "__isBool", .arity = 1, .f = isType(&.{.bool}) },
    .{ .name = "__isPath", .arity = 1, .f = isType(&.{.path}) },
    .{ .name = "__isList", .arity = 1, .f = isType(&.{.list}) },
    .{ .name = "__isAttrs", .arity = 1, .f = isType(&.{.set}) },
    .{ .name = "__seq", .arity = 2, .f = seq },
    .{ .name = "__deepSeq", .arity = 2, .f = deepSeq },
    .{ .name = "abort", .arity = 1, .f = abort },
    .{ .name = "throw", .arity = 1, .f = throw },
    .{ .name = "__trace", .arity = 2, .f = trace },
    .{ .name = "__traceVerbose", .arity = 2, .f = second },
    .{ .name = "__warn", .arity = 2, .f = warn },
    .{ .name = "__addErrorContext", .arity = 2, .f = addErrorContext },
    .{ .name = "__tryEval", .arity = 1, .f = tryEval },
    .{ .name = "__functionArgs", .arity = 1, .f = functionArgs },
    .{ .name = "__unsafeGetAttrPos", .arity = 2, .f = unsafeGetAttrPos },
    .{ .name = "__findFile", .arity = 2, .f = findFile },
};

fn importPath(ev: *Evaluator, v_in: Value, pos: Pos) Error![]const u8 {
    const v = try ev.force(v_in);
    switch (v.view()) {
        .path => |p| return p.bytes(),
        // Changed for builtins: paths. A store path this evaluation made
        // reads what it stands for.
        .string => {
            try @import("../lint/purity.zig").ifd(ev, v.as(value.String).context(), pos);
            return @import("paths.zig").realisePath(ev, v, pos);
        },
        // eval.cc:coerceToString tries `__toString` before `outPath`.
        .attrs => |a| {
            if (a.get(ev.s.__toString)) |f| return importPath(ev, try ev.call1(try ev.forceCell(&f.cell), v, pos), pos);
            if (a.get(ev.s.outPath)) |o| return importPath(ev, o.cell.get(), pos);
        },
        else => {},
    }
    return ev.typeError("a path", v, pos, "while evaluating the argument passed to import");
}

fn import(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const p = try importPath(ev, args[0], pos);
    if (try @import("derivation.zig").importDerivation(ev, p, pos)) |v| return v;
    return import_.evalFile(ev, p, pos);
}

fn scopedImport(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const scope = try ev.forceAttrs(args[0], pos, "while evaluating the first argument passed to builtins.scopedImport");
    return import_.scopedImport(ev, scope, try importPath(ev, args[1], pos), pos);
}

fn toString(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    return ev.coerceToStringValue(args[0], pos, "while evaluating the first argument passed to builtins.toString", .{ .coerce_more = true, .copy_to_store = false });
}

fn typeOf(ev: *Evaluator, args: []const Value, _: Pos) Error!Value {
    const v = try ev.force(args[0]);
    return ev.mkStringStatic(v.typeOf().name(), &.{});
}

fn isType(comptime types: []const value.Type) *const Evaluator.PrimFn {
    return struct {
        fn f(ev: *Evaluator, args: []const Value, _: Pos) Error!Value {
            const t = (try ev.force(args[0])).typeOf();
            inline for (types) |want| if (t == want) return .true;
            return .false;
        }
    }.f;
}

fn seq(ev: *Evaluator, args: []const Value, _: Pos) Error!Value {
    _ = try ev.force(args[0]);
    return ev.force(args[1]);
}

fn deepSeq(ev: *Evaluator, args: []const Value, _: Pos) Error!Value {
    _ = try ev.forceDeep(args[0]);
    return ev.force(args[1]);
}

fn second(ev: *Evaluator, args: []const Value, _: Pos) Error!Value {
    return ev.force(args[1]);
}

fn message(ev: *Evaluator, v: Value, pos: Pos, ctx: []const u8, copy: bool) Error![]const u8 {
    const s = try ev.coerceToStringValue(v, pos, ctx, .{ .copy_to_store = copy });
    return s.as(value.String).bytes();
}

fn abort(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const s = try message(ev, args[0], pos, "while evaluating the error message passed to builtins.abort", true);
    return ev.fail(.abort, pos, "evaluation aborted with the following error message: '{s}'", .{s});
}

fn throw(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const s = try message(ev, args[0], pos, "while evaluating the error message passed to builtin.throw", true);
    return ev.fail(.throw, pos, "{s}", .{s});
}

fn say(ev: *Evaluator, comptime fmt: []const u8, args: anytype) Error!void {
    return ev.effect(fmt, args);
}

fn trace(ev: *Evaluator, args: []const Value, _: Pos) Error!Value {
    const v = try ev.force(args[0]);
    if (v.kind() == .string) try say(ev, "trace: {s}", .{v.as(value.String).bytes()}) else try say(ev, "trace: {f}", .{print.short(ev, v)});
    return ev.force(args[1]);
}

fn warn(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const s = try ev.forceString(args[0], pos, "while evaluating the first argument; the message passed to builtins.warn");
    try say(ev, "evaluation warning: {s}", .{s.bytes()});
    return ev.force(args[1]);
}

fn addErrorContext(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    return ev.force(args[1]) catch |e| {
        if (e != error.EvalFailed) return e;
        const saved = ev.failure;
        ev.failure = null;
        const msg = message(ev, args[0], pos, "while evaluating the error message passed to builtins.addErrorContext", false) catch |e2| {
            ev.clearFailure();
            ev.failure = saved;
            return e2;
        };
        ev.clearFailure();
        ev.failure = saved;
        return ev.addTrace(e, .none, "{s}", .{msg});
    };
}

fn tryEval(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    var success: Value = .true;
    const v = tryForce(ev, args[0]) catch |e| blk: {
        if (e != error.EvalFailed) return e;
        switch (ev.failureKind().?) {
            .throw, .assert => {},
            else => return e,
        }
        ev.clearFailure();
        success = .false;
        break :blk Value.false;
    };
    var entries = [_]value.Attr{
        .{ .sym = ev.s.success, .pos = .none, .cell = .init(success) },
        .{ .sym = ev.s.value, .pos = .none, .cell = .init(v) },
    };
    return ev.mkAttrs(&entries, pos);
}

/// `tryEval`'s force; under the census, inside an escape-tracking scope.
inline fn tryForce(ev: *Evaluator, v: Value) Error!Value {
    if (!Evaluator.census.enabled) return ev.force(v);
    const scope = ev.local.arena.census.scopeEnter(ev.local.arena.used);
    const r = ev.force(v);
    if (scope) {
        const c = &ev.local.arena.census;
        const bytes, const escapes = c.scopeLeave(ev.local.arena.used);
        c.try_scopes[0] += 1;
        const caught = if (r) |_| false else |e| e == error.EvalFailed and switch (ev.failureKind().?) {
            .throw, .assert => true,
            else => false,
        };
        if (caught) {
            c.try_scopes[1] += 1;
            c.try_scopes[2] += bytes;
            if (escapes == 0) {
                c.try_scopes[3] += 1;
                c.try_scopes[4] += bytes;
            }
        }
    }
    return r;
}

fn functionArgs(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const v = try ev.force(args[0]);
    switch (v.view()) {
        .primop, .primop_app => return ev.emptyAttrs(),
        .lambda => |l| switch (l.lam.param) {
            .ident => return ev.emptyAttrs(),
            .formals => |p| {
                const out = try ev.allocAttrs(p.formals.len);
                for (p.formals, out.raw()) |f, *a| a.* = .{ .sym = f.sym, .pos = f.pos, .cell = .init(.fromBool(f.default != null)) };
                return .fromPtr(.ptr, out);
            },
        },
        else => return ev.fail(.type, pos, "'functionArgs' requires a function", .{}),
    }
}

fn unsafeGetAttrPos(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const name = try ev.forceStringNoCtx(args[0], pos, "while evaluating the first argument passed to builtins.unsafeGetAttrPos");
    // A lookup probes a union's leaves: no flat copy. A name never interned
    // is in no set.
    const attrs = try ev.forceSet(args[1], pos, "while evaluating the second argument passed to builtins.unsafeGetAttrPos");
    if (Evaluator.census.enabled) ev.local.arena.census.get_attr_pos_calls += 1;
    const s = ev.interner.get(name) orelse return .null;
    const a = Evaluator.getAttr(attrs, s) orelse return .null;
    return ev.mkPosAttrs(a.pos);
}

fn findFile(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const l = try ev.forceList(args[0], pos, "while evaluating the first argument passed to builtins.findFile");
    var entries: std.ArrayList(Evaluator.SearchPathEntry) = .empty;
    defer entries.deinit(ev.gpa);
    for (l.cells()) |*c| {
        const a = try ev.forceAttrs(c.get(), pos, "while evaluating an element of the list passed to builtins.findFile");
        const prefix = if (a.get(ev.s.prefix)) |p|
            try ev.forceStringNoCtx(p.cell.get(), pos, "while evaluating the `prefix` attribute of an element of the list passed to builtins.findFile")
        else
            "";
        const pa = a.get(ev.s.path) orelse
            return ev.fail(.type, pos, "attribute 'path' missing in an element of the list passed to builtins.findFile", .{});
        const path = try ev.coerceToStringValue(pa.cell.get(), pos, "while evaluating the `path` attribute of an element of the list passed to builtins.findFile", .{ .copy_to_store = false });
        try entries.append(ev.gpa, .{ .prefix = prefix, .path = path.as(value.String).bytes() });
    }
    const name = try ev.forceStringNoCtx(args[1], pos, "while evaluating the second argument passed to builtins.findFile");
    return ev.mkPath(try import_.findFile(ev, entries.items, name, pos));
}
