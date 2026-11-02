//! Value printers: the `nix-instantiate --eval` format (print.cc:printAmbiguous),
//! JSON (value-to-json.cc), and the short form of error messages.

const std = @import("std");
const bytes = @import("../bytes.zig");
const Writer = std.Io.Writer;
const Evaluator = @import("Evaluator.zig");
const Error = Evaluator.Error;
const value = @import("../runtime/value.zig");
const Value = value.Value;
const Ctx = value.Ctx;
const Pos = @import("../syntax/pos.zig").Pos;

/// C's `%g` at precision 6, as `std::ostream << double` prints; libc's
/// formatter, since a correctly rounded `%g` is exactly what Nix prints.
pub fn writeFloatG(w: *Writer, f: f64) Writer.Error!void {
    var buf: [64]u8 = undefined;
    const n = snprintf(&buf, buf.len, "%g", f);
    try w.writeAll(buf[0..@intCast(n)]);
}

extern "c" fn snprintf(buf: [*]u8, n: usize, fmt: [*:0]const u8, ...) c_int;

fn stripZeros(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '.') == null) return s;
    const t = std.mem.trimEnd(u8, s, "0");
    return if (t.len > 0 and t[t.len - 1] == '.') t[0 .. t.len - 1] else t;
}

/// Shortest round-trip float, as nlohmann::json prints it.
pub fn writeFloatJson(w: *Writer, f: f64) Writer.Error!void {
    if (!std.math.isFinite(f)) return w.writeAll("null");
    var sbuf: [64]u8 = undefined;
    const sci = std.fmt.bufPrint(&sbuf, "{e}", .{f}) catch unreachable;
    const e_at = std.mem.indexOfScalar(u8, sci, 'e').?;
    const exp = std.fmt.parseInt(i32, sci[e_at + 1 ..], 10) catch unreachable;
    if (exp >= -4 and exp < 15) {
        var dbuf: [400]u8 = undefined;
        const s = std.fmt.bufPrint(&dbuf, "{d}", .{f}) catch unreachable;
        try w.writeAll(s);
        if (std.mem.indexOfScalar(u8, s, '.') == null) try w.writeAll(".0");
        return;
    }
    try w.writeAll(sci[0..e_at]);
    try w.print("e{c}{d:0>2}", .{ @as(u8, if (exp < 0) '-' else '+'), @abs(exp) });
}

pub fn writeLiteralString(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (s, 0..) |c, i| switch (c) {
        '"', '\\' => {
            try w.writeByte('\\');
            try w.writeByte(c);
        },
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        '$' => try w.writeAll(if (i + 1 < s.len and s[i + 1] == '{') "\\$" else "$"),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// print.cc:isVarName.
fn isVarName(s: []const u8) bool {
    const keywords = [_][]const u8{ "if", "then", "else", "assert", "with", "let", "in", "rec", "inherit" };
    if (s.len == 0) return false;
    for (keywords) |k| if (std.mem.eql(u8, s, k)) return false;
    if (std.ascii.isDigit(s[0]) or s[0] == '-' or s[0] == '\'') return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '\'')) return false;
    return true;
}

/// print.cc:printAttributeName: bare when it is an identifier.
pub fn writeAttrName(w: *Writer, name: []const u8) Writer.Error!void {
    if (isVarName(name)) return w.writeAll(name);
    return writeLiteralString(w, name);
}

/// The attributes of a set in the order Nix prints them, by name bytes. The
/// first 8 bytes of each name decide most comparisons without reading the
/// names themselves.
pub fn lexicographic(ev: *Evaluator, a: *value.Attrs) error{OutOfMemory}![]*value.Attr {
    const Keyed = struct { prefix: u64, attr: *value.Attr };
    const keyed = try ev.gpa.alloc(Keyed, a.len);
    defer ev.gpa.free(keyed);
    for (a.attrs(), keyed) |*at, *k| k.* = .{ .prefix = ev.interner.prefix(at.sym), .attr = at };
    std.sort.pdq(Keyed, keyed, ev, struct {
        fn less(e: *Evaluator, x: Keyed, y: Keyed) bool {
            if (x.prefix != y.prefix) return x.prefix < y.prefix;
            return std.mem.order(u8, e.interner.name(x.attr.sym), e.interner.name(y.attr.sym)) == .lt;
        }
    }.less);
    const out = try ev.gpa.alloc(*value.Attr, a.len);
    for (keyed, out) |k, *o| o.* = k.attr;
    return out;
}

/// `nix-instantiate --eval` output, which does not force; `--strict` forces first.
pub fn writeAmbiguous(ev: *Evaluator, w: *Writer, v: Value) (Error || Writer.Error)!void {
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(ev.gpa);
    return ambiguous(ev, w, v, 0, &seen, 0);
}

fn ambiguous(ev: *Evaluator, w: *Writer, v: Value, cell: u64, seen: *std.AutoHashMapUnmanaged(u64, void), depth: usize) (Error || Writer.Error)!void {
    if (depth > Evaluator.max_call_depth) return ev.fail(.stack_overflow, .none, "stack overflow; max-call-depth exceeded", .{});
    if (v.isThunk()) {
        const t = v.thunkCells();
        const st = t.state.get();
        if (st == .empty) return ambiguous(ev, w, t.code.get(), cell, seen, depth);
        // Only this thread's own claim is the program's recursion; a helper's
        // claim, like its speculated result, is work the program never asked for.
        if (st.isBlackhole() and st.claimer() == ev.par.id) return w.writeAll("«potential infinite recursion»");
        return w.writeAll("<CODE>");
    }
    switch (v.view()) {
        .int => |i| try w.print("{d}", .{i}),
        .float => |f| try writeFloatG(w, f),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .null => try w.writeAll("null"),
        .string => |s| try writeLiteralString(w, s.bytes()),
        .path => |p| try w.writeAll(p.bytes()),
        .attrs => |a| {
            if (a.len > 0 and (try seen.getOrPut(ev.gpa, v.bits())).found_existing) return w.writeAll("«repeated»");
            try w.writeAll("{ ");
            const sorted = try lexicographic(ev, a);
            defer ev.gpa.free(sorted);
            for (sorted) |at| {
                try writeAttrName(w, ev.interner.name(at.sym));
                try w.writeAll(" = ");
                try ambiguous(ev, w, at.cell.get(), @intFromPtr(&at.cell), seen, depth + 1);
                try w.writeAll("; ");
            }
            try w.writeByte('}');
        },
        .list => |l| {
            // Nix keys a repeated list on the address of the slot it was read from.
            if (l.len > 0 and (try seen.getOrPut(ev.gpa, cell)).found_existing) return w.writeAll("«repeated»");
            try w.writeAll("[ ");
            for (l.cells()) |*c| {
                try ambiguous(ev, w, c.get(), @intFromPtr(c), seen, depth + 1);
                try w.writeByte(' ');
            }
            try w.writeByte(']');
        },
        .lambda => try w.writeAll("<LAMBDA>"),
        .primop => try w.writeAll("<PRIMOP>"),
        .primop_app => try w.writeAll("<PRIMOP-APP>"),
        .thunk => unreachable,
    }
}

/// The short form of a value in error messages, for `{f}`.
pub fn short(ev: *Evaluator, v: Value) Short {
    return .{ .ev = ev, .v = v };
}

pub const Short = struct {
    ev: *Evaluator,
    v: Value,

    pub fn format(s: Short, w: *Writer) Writer.Error!void {
        return showShort(s.ev, w, s.v, 0);
    }
};

fn showShort(ev: *Evaluator, w: *Writer, v: Value, depth: usize) Writer.Error!void {
    if (v.isThunk()) {
        const t = v.thunkCells();
        if (t.state.get() == .empty) return showShort(ev, w, t.code.get(), depth);
        return w.writeAll("«thunk»");
    }
    switch (v.view()) {
        .int => |i| try w.print("{d}", .{i}),
        .float => |f| try writeFloatG(w, f),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .null => try w.writeAll("null"),
        .string => |s| try writeLiteralString(w, s.bytes()),
        .path => |p| try w.writeAll(p.bytes()),
        .attrs => |a| {
            if (depth >= 1) return w.writeAll("{ ... }");
            try w.writeByte('{');
            const sorted = lexicographic(ev, a) catch return error.WriteFailed;
            defer ev.gpa.free(sorted);
            for (sorted, 0..) |at, n| {
                if (n >= 8) {
                    try w.writeAll(" «more attributes elided»");
                    break;
                }
                try w.writeByte(' ');
                try w.writeAll(ev.interner.name(at.sym));
                try w.writeAll(" = ");
                try showShort(ev, w, at.cell.get(), depth + 1);
                try w.writeByte(';');
            }
            try w.writeAll(" }");
        },
        .list => |l| {
            if (depth >= 1) return w.writeAll("[ ... ]");
            try w.writeByte('[');
            for (l.cells(), 0..) |*c, n| {
                if (n >= 8) {
                    try w.writeAll(" «more items elided»");
                    break;
                }
                try w.writeByte(' ');
                try showShort(ev, w, c.get(), depth + 1);
            }
            try w.writeAll(" ]");
        },
        .lambda => |l| {
            try w.writeAll("«lambda");
            if (l.lam.name) |n| try w.print(" {s}", .{ev.interner.name(n)});
            try w.print(" @ {f}»", .{ev.files.at(l.lam.pos)});
        },
        .primop => |p| try w.print("«primop {s}»", .{p.name()}),
        .primop_app => |p| try w.print("«partially applied primop {s}»", .{p.op.name()}),
        .thunk => unreachable,
    }
}

pub fn writeCtx(w: *Writer, c: Ctx) Writer.Error!void {
    switch (c.kind) {
        .opaque_path, .impure_path, .impure_meta => try w.writeAll(c.path),
        .drv_deep => try w.print("={s}", .{c.path}),
        .built => try w.print("!{s}!{s}", .{ c.output, c.path }),
    }
}

/// A printer's error once the output is in memory: a write that failed is
/// an allocation that failed.
pub fn inMemory(e: (Error || Writer.Error)) Error {
    return switch (e) {
        error.WriteFailed => error.OutOfMemory,
        else => |x| x,
    };
}

pub fn writeJsonString(ev: *Evaluator, w: *Writer, s: []const u8) (Error || Writer.Error)!void {
    if (!std.unicode.utf8ValidateSlice(s))
        return ev.fail(.eval, .none, "JSON serialization error: invalid UTF-8 byte in string", .{});
    try w.writeByte('"');
    var done: usize = 0;
    while (bytes.findJsonEscape(s, done)) |i| {
        try w.writeAll(s[done..i]);
        const c = s[i];
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            0x08 => try w.writeAll("\\b"),
            0x0c => try w.writeAll("\\f"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.print("\\u{x:0>4}", .{c}),
        }
        done = i + 1;
    }
    try w.writeAll(s[done..]);
    try w.writeByte('"');
}

/// value-to-json.cc:printValueAsJSON. Counts against the call depth, so a
/// deep structure fails with a stack overflow.
pub fn writeJson(ev: *Evaluator, w: *Writer, v_in: Value, ctx: *std.ArrayList(Ctx), strict: bool, pos: Pos) (Error || Writer.Error)!void {
    if (ev.call_depth >= Evaluator.max_call_depth) return ev.fail(.stack_overflow, pos, "stack overflow; max-call-depth exceeded", .{});
    try ev.checkStack();
    ev.call_depth += 1;
    defer ev.call_depth -= 1;
    const v = if (strict) try ev.force(v_in) else v_in;
    if (v.isThunk()) return ev.fail(.type, pos, "cannot convert a thunk to JSON", .{});
    switch (v.view()) {
        .int => |i| try w.print("{d}", .{i}),
        .float => |f| try writeFloatJson(w, f),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .null => try w.writeAll("null"),
        .string => |s| {
            try ctx.appendSlice(ev.gpa, s.context());
            try writeJsonString(ev, w, s.bytes());
        },
        .path => |p| {
            const sp = try ev.copyPathToStore(p.bytes(), pos);
            try ctx.append(ev.gpa, .{ .kind = .opaque_path, .path = sp });
            try writeJsonString(ev, w, sp);
        },
        .attrs => |a| {
            if (a.get(ev.s.__toString)) |f| {
                const fv = try ev.forceCell(&f.cell);
                const r = try ev.call1(fv, v, pos);
                var out: std.ArrayList(u8) = .empty;
                defer out.deinit(ev.gpa);
                try ev.coerceToString(r, &out, ctx, pos, "", .{ .copy_to_store = false });
                return writeJsonString(ev, w, out.items);
            }
            if (a.get(ev.s.outPath)) |o| return writeJson(ev, w, o.cell.get(), ctx, strict, o.pos);
            if (strict) ev.offerAttrsCoerce(a);
            try w.writeByte('{');
            const sorted = try lexicographic(ev, a);
            defer ev.gpa.free(sorted);
            for (sorted, 0..) |at, i| {
                if (i > 0) try w.writeByte(',');
                try writeJsonString(ev, w, ev.interner.name(at.sym));
                try w.writeByte(':');
                writeJson(ev, w, at.cell.get(), ctx, strict, at.pos) catch |e| switch (e) {
                    error.EvalFailed => return ev.addTrace(error.EvalFailed, at.pos, "while evaluating attribute '{s}'", .{ev.interner.name(at.sym)}),
                    else => return e,
                };
            }
            try w.writeByte('}');
        },
        .list => |l| {
            if (strict) ev.offerListCoerce(l);
            try w.writeByte('[');
            for (l.cells(), 0..) |*c, i| {
                if (i > 0) try w.writeByte(',');
                writeJson(ev, w, c.get(), ctx, strict, pos) catch |e| switch (e) {
                    error.EvalFailed => return ev.addTrace(error.EvalFailed, pos, "while evaluating list element at index {d}", .{i}),
                    else => return e,
                };
            }
            try w.writeByte(']');
        },
        .lambda, .primop, .primop_app => return ev.fail(.type, pos, "cannot convert a function to JSON", .{}),
        .thunk => unreachable,
    }
}

test "float formatting edge cases" {
    const cases = [_]struct { f64, []const u8, []const u8 }{
        .{ std.math.nan(f64), "nan", "null" },
        .{ std.math.inf(f64), "inf", "null" },
        .{ -std.math.inf(f64), "-inf", "null" },
        .{ -0.0, "-0", "-0.0" },
        .{ 1e300, "1e+300", "1e+300" },
        .{ 5e-324, "4.94066e-324", "5e-324" },
        .{ 0.0, "0", "0.0" },
        .{ -1e300, "-1e+300", "-1e+300" },
        .{ std.math.floatMin(f64), "2.22507e-308", "2.2250738585072014e-308" },
        .{ 1.0, "1", "1.0" },
        .{ 0.1, "0.1", "0.1" },
        .{ 123456.0, "123456", "123456.0" },
        .{ 1234567.0, "1.23457e+06", "1234567.0" },
        .{ 0.0001, "0.0001", "0.0001" },
    };
    for (cases) |c| {
        var b1: [64]u8 = undefined;
        var w1: Writer = .fixed(&b1);
        try writeFloatG(&w1, c[0]);
        try std.testing.expectEqualStrings(c[1], w1.buffered());
        var b2: [64]u8 = undefined;
        var w2: Writer = .fixed(&b2);
        try writeFloatJson(&w2, c[0]);
        try std.testing.expectEqualStrings(c[2], w2.buffered());
    }
}
