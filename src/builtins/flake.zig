//! The flake primops (flake-primops.cc): parseFlakeRef, flakeRefToString,
//! getFlake. Ported from ../iets/src/flake/.

const std = @import("std");
const Op = @import("../builtins.zig").Op;
const Evaluator = @import("../eval/Evaluator.zig");
const Error = Evaluator.Error;
const value = @import("../runtime/value.zig");
const Value = value.Value;
const Pos = @import("../syntax/pos.zig").Pos;
const Diag = @import("../diag.zig").Diag;
const text = @import("../syntax/text.zig");
const flakeref = @import("../flake/flakeref.zig");
const Attrs = @import("../source/attrs.zig").Attrs;
const AttrVal = @import("../source/attrs.zig").AttrVal;

pub const ops = [_]Op{
    .{ .name = "__getFlake", .arity = 1, .f = @import("../flake.zig").getFlake },
    .{ .name = "__parseFlakeRef", .arity = 1, .f = parseFlakeRef },
    .{ .name = "__flakeRefToString", .arity = 1, .f = flakeRefToString },
};

/// A flake reference error as an evaluation error: an unsupported
/// reference keeps its kind.
pub fn refError(ev: *Evaluator, e: flakeref.Error, d: *const Diag, pos: Pos) Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Unsupported => ev.fail(.unsupported, pos, "{s}", .{d.message()}),
        error.Flake => ev.fail(.eval, pos, "{s}", .{d.message()}),
    };
}

fn parseFlakeRef(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const raw = try ev.forceStringNoCtx(args[0], pos, "while evaluating the argument passed to builtins.parseFlakeRef");
    var tmp: std.heap.ArenaAllocator = .init(ev.gpa);
    defer tmp.deinit();
    const a = tmp.allocator();
    var d: Diag = .init(a);
    var p = flakeref.parseAbsolute(a, try text.lossyAlloc(a, raw), &d) catch |e| return refError(ev, e, &d, pos);
    if (p.dir.len > 0) try p.input.put(a, "dir", .{ .str = p.dir });
    const entries = try ev.gpa.alloc(value.Attr, p.input.len());
    defer ev.gpa.free(entries);
    for (p.input.items(), entries) |e, *out| {
        const v: Value = switch (e.value) {
            .str => |s| try ev.mkString(s),
            .int => |n| try ev.mkInt(@bitCast(n)),
            .bool => |b| .fromBool(b),
        };
        out.* = .{ .sym = try ev.sym(e.key), .pos = pos, .cell = .init(v) };
    }
    return ev.mkAttrs(entries, pos);
}

fn flakeRefToString(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const in = try ev.forceAttrs(args[0], pos, "while evaluating the argument passed to builtins.flakeRefToString");
    var tmp: std.heap.ArenaAllocator = .init(ev.gpa);
    defer tmp.deinit();
    const a = tmp.allocator();
    var m: Attrs = .{};
    for (in.attrs()) |*at| {
        const name = try text.lossyAlloc(a, ev.interner.name(at.sym));
        const v = try ev.force(at.cell.get());
        const bad = "flake ref attribute '{s}' has a bad type";
        const val: AttrVal = switch (v.view()) {
            .int => |n| if (n >= 0) .{ .int = @intCast(n) } else return ev.fail(.eval, pos, bad, .{name}),
            .bool => |b| .{ .bool = b },
            .string => |s| .{ .str = try text.lossyAlloc(a, s.bytes()) },
            else => return ev.fail(.eval, pos, bad, .{name}),
        };
        try m.put(a, name, val);
    }
    var d: Diag = .init(a);
    const s = flakeref.attrsToString(a, &m, &d) catch |e| return refError(ev, e, &d, pos);
    return ev.mkString(s);
}
