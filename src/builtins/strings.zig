//! String primops: length, substrings, joining, versions, derivation names
//! and path components.

const std = @import("std");
const Op = @import("../builtins.zig").Op;
const Evaluator = @import("../eval/Evaluator.zig");
const Error = Evaluator.Error;
const value = @import("../runtime/value.zig");
const Value = value.Value;
const Ctx = value.Ctx;
const Pos = @import("../syntax/pos.zig").Pos;
const import_ = @import("../eval/import.zig");

pub const ops = [_]Op{
    .{ .name = "__stringLength", .arity = 1, .f = stringLength },
    .{ .name = "__substring", .arity = 3, .f = substring },
    .{ .name = "__concatStringsSep", .arity = 2, .f = concatStringsSep },
    .{ .name = "__splitVersion", .arity = 1, .f = splitVersion },
    .{ .name = "__compareVersions", .arity = 2, .f = compareVersions },
    .{ .name = "__parseDrvName", .arity = 1, .f = parseDrvName },
    .{ .name = "baseNameOf", .arity = 1, .f = baseNameOf },
    .{ .name = "dirOf", .arity = 1, .f = dirOf },
};

/// The coerced bytes of a value and their context, in gpa-owned buffers.
const Coerced = struct {
    out: std.ArrayList(u8) = .empty,
    ctx: std.ArrayList(Ctx) = .empty,

    fn deinit(c: *Coerced, gpa: std.mem.Allocator) void {
        c.out.deinit(gpa);
        c.ctx.deinit(gpa);
    }
};

fn coerce(ev: *Evaluator, v: Value, pos: Pos, err_ctx: []const u8, opts: Evaluator.CoerceOpts) Error!Coerced {
    var c: Coerced = .{};
    errdefer c.deinit(ev.gpa);
    try ev.coerceToString(v, &c.out, &c.ctx, pos, err_ctx, opts);
    return c;
}

fn stringLength(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const v = try ev.force(args[0]);
    if (v.kind() == .string) return ev.mkInt(@intCast(v.as(value.String).len));
    var c = try coerce(ev, v, pos, "while evaluating the argument passed to builtins.stringLength", .{});
    defer c.deinit(ev.gpa);
    return ev.mkInt(@intCast(c.out.items.len));
}

fn clampedSlice(b: []const u8, start_i: i64, len: i64) []const u8 {
    const start = @min(@as(u64, @intCast(start_i)), b.len);
    const end = if (len < 0) b.len else @min(start +| @as(u64, @intCast(len)), b.len);
    return b[start..end];
}

fn substring(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const start = try ev.forceInt(args[0], pos, "while evaluating the first argument (the start offset) passed to builtins.substring");
    if (start < 0) return ev.fail(.eval, pos, "negative start position in 'substring'", .{});
    const len = try ev.forceInt(args[1], pos, "while evaluating the second argument (the substring length) passed to builtins.substring");
    const v = try ev.force(args[2]);
    // A string slices in place and keeps its whole context.
    if (v.kind() == .string) {
        const s = v.as(value.String);
        if (len == 0) return ev.mkStringStatic("", s.context());
        return ev.mkStringStatic(clampedSlice(s.bytes(), start, len), s.context());
    }
    var c = try coerce(ev, v, pos, "while evaluating the third argument (the string) passed to builtins.substring", .{});
    defer c.deinit(ev.gpa);
    return ev.mkStringCtx(clampedSlice(c.out.items, start, len), c.ctx.items);
}

fn concatStringsSep(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const sep = try ev.forceString(args[0], pos, "while evaluating the first argument (the separator string) passed to builtins.concatStringsSep");
    const l = try ev.forceList(args[1], pos, "while evaluating the second argument (the list of strings to concat) passed to builtins.concatStringsSep");
    ev.offerListCoerce(l);
    var c: Coerced = .{};
    defer c.deinit(ev.gpa);
    try c.ctx.appendSlice(ev.gpa, sep.context());
    for (l.cells(), 0..) |*cell, i| {
        if (i > 0) try c.out.appendSlice(ev.gpa, sep.bytes());
        try ev.coerceToString(cell.get(), &c.out, &c.ctx, pos, "while evaluating one element of the list of strings to concat passed to builtins.concatStringsSep", .{});
    }
    return ev.mkStringCtx(c.out.items, c.ctx.items);
}

/// Mirrors names.cc:nextComponent.
fn nextComponent(s: []const u8, p: *usize) []const u8 {
    while (p.* < s.len and (s[p.*] == '.' or s[p.*] == '-')) p.* += 1;
    if (p.* >= s.len) return "";
    const start = p.*;
    if (std.ascii.isDigit(s[p.*])) {
        while (p.* < s.len and std.ascii.isDigit(s[p.*])) p.* += 1;
    } else {
        while (p.* < s.len and !std.ascii.isDigit(s[p.*]) and s[p.*] != '.' and s[p.*] != '-') p.* += 1;
    }
    return s[start..p.*];
}

/// names.cc:componentsLT reads a component with `string2Int<int>`, so a
/// value above 2147483647 is not a number and orders as text.
fn parseComponentInt(c: []const u8) ?i32 {
    if (c.len == 0) return null;
    var n: i32 = 0;
    for (c) |b| {
        if (!std.ascii.isDigit(b)) return null;
        n = std.math.mul(i32, n, 10) catch return null;
        n = std.math.add(i32, n, b - '0') catch return null;
    }
    return n;
}

/// Mirrors names.cc:componentsLT.
fn componentsLt(c1: []const u8, c2: []const u8) bool {
    const n1 = parseComponentInt(c1);
    const n2 = parseComponentInt(c2);
    if (n1 != null and n2 != null) return n1.? < n2.?;
    if (n1 == null and n2 != null and c1.len == 0) return true;
    const pre1 = std.mem.eql(u8, c1, "pre");
    const pre2 = std.mem.eql(u8, c2, "pre");
    if (pre1 and !pre2) return true;
    if (pre2) return false;
    if (n2 != null) return true;
    if (n1 != null) return false;
    return std.mem.order(u8, c1, c2) == .lt;
}

/// Mirrors names.cc:compareVersions.
pub fn compareVersionStrings(a: []const u8, b: []const u8) std.math.Order {
    var p1: usize = 0;
    var p2: usize = 0;
    while (true) {
        if (p1 >= a.len and p2 >= b.len) return .eq;
        const c1 = nextComponent(a, &p1);
        const c2 = nextComponent(b, &p2);
        if (componentsLt(c1, c2)) return .lt;
        if (componentsLt(c2, c1)) return .gt;
        if (c1.len == 0 and c2.len == 0) return .eq;
    }
}

fn splitVersion(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const s = try ev.forceStringNoCtx(args[0], pos, "while evaluating the first argument passed to builtins.splitVersion");
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(ev.gpa);
    var p: usize = 0;
    while (true) {
        const c = nextComponent(s, &p);
        if (c.len == 0) break;
        try items.append(ev.gpa, try ev.mkStringStatic(c, &.{}));
    }
    return ev.mkList(items.items);
}

fn compareVersions(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const a = try ev.forceStringNoCtx(args[0], pos, "while evaluating the first argument passed to builtins.compareVersions");
    const b = try ev.forceStringNoCtx(args[1], pos, "while evaluating the second argument passed to builtins.compareVersions");
    return .immInt(switch (compareVersionStrings(a, b)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    });
}

/// Mirrors names.cc:DrvName::DrvName: the version starts after the first
/// dash that is not followed by a letter.
pub fn splitDrvName(s: []const u8) struct { []const u8, []const u8 } {
    for (s, 0..) |c, i| {
        if (c == '-' and i + 1 < s.len and !std.ascii.isAlphabetic(s[i + 1])) return .{ s[0..i], s[i + 1 ..] };
    }
    return .{ s, "" };
}

fn parseDrvName(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const s = try ev.forceStringNoCtx(args[0], pos, "while evaluating the first argument passed to builtins.parseDrvName");
    const name, const version = splitDrvName(s);
    var entries = [_]value.Attr{
        .{ .sym = ev.s.name, .pos = .none, .cell = .init(try ev.mkStringStatic(name, &.{})) },
        .{ .sym = try ev.sym("version"), .pos = .none, .cell = .init(try ev.mkStringStatic(version, &.{})) },
    };
    return ev.mkAttrs(&entries, pos);
}

fn baseNameOf(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    var c = try coerce(ev, args[0], pos, "while evaluating the first argument passed to builtins.baseNameOf", .{ .copy_to_store = false });
    defer c.deinit(ev.gpa);
    const s = c.out.items;
    var end = s.len;
    if (end > 0 and s[end - 1] == '/') end -= 1;
    const start = if (std.mem.lastIndexOfScalar(u8, s[0..end], '/')) |i| i + 1 else 0;
    return ev.mkStringCtx(s[start..end], c.ctx.items);
}

fn dirOf(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const v = try ev.force(args[0]);
    if (v.kind() == .path) return ev.mkPath(import_.dirOf(v.as(value.Path).bytes()));
    var c = try coerce(ev, v, pos, "while evaluating the first argument passed to 'builtins.dirOf'", .{ .copy_to_store = false });
    defer c.deinit(ev.gpa);
    return ev.mkStringCtx(import_.dirOf(c.out.items), c.ctx.items);
}

test "compareVersions" {
    const cases = [_]struct { []const u8, []const u8, std.math.Order }{
        .{ "1.0", "2.3", .lt },
        .{ "2.1", "2.3", .lt },
        .{ "2.3", "2.3", .eq },
        .{ "2.5", "2.3", .gt },
        .{ "3.1", "2.3", .gt },
        .{ "2.3.1", "2.3", .gt },
        .{ "2.3.1", "2.3a", .gt },
        .{ "2.3pre1", "2.3", .lt },
        .{ "2.3", "2.3pre", .gt },
        .{ "2.3pre3", "2.3pre12", .lt },
        .{ "2.3a", "2.3c", .lt },
        .{ "2.3pre1", "2.3c", .lt },
        .{ "2.3pre1", "2.3q", .lt },
        .{ "4294967296", "4294967297", .lt },
    };
    for (cases) |c| try std.testing.expectEqual(c[2], compareVersionStrings(c[0], c[1]));
}

test "splitDrvName" {
    const n, const v = splitDrvName("hello-2.10-pre");
    try std.testing.expectEqualStrings("hello", n);
    try std.testing.expectEqualStrings("2.10-pre", v);
}
