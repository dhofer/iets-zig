//! `builtins.toXML`, byte-exact with value-to-xml.cc and xml-writer.cc.

const std = @import("std");
const Evaluator = @import("../../eval/Evaluator.zig");
const Error = Evaluator.Error;
const value = @import("../../runtime/value.zig");
const Value = value.Value;
const Ctx = value.Ctx;
const Pos = @import("../../syntax/pos.zig").Pos;
const print = @import("../../eval/print.zig");

pub fn toXml(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    var x: Xml = .{ .ev = ev };
    defer x.deinit();
    try x.raw("<?xml version='1.0' encoding='utf-8'?>\n<expr>\n");
    try x.printValue(args[0], 1, pos);
    try x.raw("</expr>\n");
    return ev.mkStringCtx(x.out.items, x.ctx.items);
}

const XmlAttr = struct { []const u8, []const u8 };

const Xml = struct {
    ev: *Evaluator,
    out: std.ArrayList(u8) = .empty,
    ctx: std.ArrayList(Ctx) = .empty,
    /// The `drvPath`s printed so far; a repeated derivation prints `<repeated />`.
    drvs_seen: std.StringHashMapUnmanaged(void) = .empty,

    fn deinit(x: *Xml) void {
        const gpa = x.ev.gpa;
        x.out.deinit(gpa);
        x.ctx.deinit(gpa);
        x.drvs_seen.deinit(gpa);
    }

    fn raw(x: *Xml, s: []const u8) Error!void {
        try x.out.appendSlice(x.ev.gpa, s);
    }

    fn indent(x: *Xml, depth: usize) Error!void {
        try x.out.appendNTimes(x.ev.gpa, ' ', depth * 2);
    }

    fn attrValue(x: *Xml, s: []const u8) Error!void {
        for (s) |c| {
            const esc: []const u8 = switch (c) {
                '"' => "&quot;",
                '<' => "&lt;",
                '>' => "&gt;",
                '&' => "&amp;",
                '\n' => "&#xA;",
                else => {
                    try x.out.append(x.ev.gpa, c);
                    continue;
                },
            };
            try x.raw(esc);
        }
    }

    fn tag(x: *Xml, depth: usize, lead: []const u8, name: []const u8, attrs: []const XmlAttr, trail: []const u8) Error!void {
        try x.indent(depth);
        try x.raw(lead);
        try x.raw(name);
        for (attrs) |a| {
            try x.raw(" ");
            try x.raw(a[0]);
            try x.raw("=\"");
            try x.attrValue(a[1]);
            try x.raw("\"");
        }
        try x.raw(trail);
    }

    fn empty(x: *Xml, depth: usize, name: []const u8, attrs: []const XmlAttr) Error!void {
        return x.tag(depth, "<", name, attrs, " />\n");
    }

    fn open(x: *Xml, depth: usize, name: []const u8, attrs: []const XmlAttr) Error!void {
        return x.tag(depth, "<", name, attrs, ">\n");
    }

    fn close(x: *Xml, depth: usize, name: []const u8) Error!void {
        return x.tag(depth, "</", name, &.{}, ">\n");
    }

    fn showAttrs(x: *Xml, a: *value.Attrs, depth: usize) Error!void {
        const sorted = try print.lexicographic(x.ev, a);
        defer x.ev.gpa.free(sorted);
        for (sorted) |at| {
            try x.open(depth, "attr", &.{.{ "name", x.ev.interner.name(at.sym) }});
            try x.printValue(at.cell.get(), depth + 1, at.pos);
            try x.close(depth, "attr");
        }
    }

    fn printValue(x: *Xml, v_in: Value, depth: usize, pos: Pos) Error!void {
        const ev = x.ev;
        if (ev.call_depth >= Evaluator.max_call_depth) return ev.fail(.stack_overflow, pos, "stack overflow; max-call-depth exceeded", .{});
        ev.call_depth += 1;
        defer ev.call_depth -= 1;
        const v = try ev.force(v_in);
        switch (v.view()) {
            .int => |i| {
                var buf: [24]u8 = undefined;
                try x.empty(depth, "int", &.{.{ "value", std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable }});
            },
            .bool => |b| try x.empty(depth, "bool", &.{.{ "value", if (b) "true" else "false" }}),
            .string => |s| {
                try x.ctx.appendSlice(ev.gpa, s.context());
                try x.empty(depth, "string", &.{.{ "value", s.bytes() }});
            },
            .path => |p| try x.empty(depth, "path", &.{.{ "value", p.bytes() }}),
            .null => try x.empty(depth, "null", &.{}),
            .float => |f| {
                var buf: [64]u8 = undefined;
                var w: std.Io.Writer = .fixed(&buf);
                print.writeFloatG(&w, f) catch unreachable;
                try x.empty(depth, "float", &.{.{ "value", w.buffered() }});
            },
            .attrs => |a| {
                if (!try ev.isDerivation(v)) {
                    try x.open(depth, "attrs", &.{});
                    try x.showAttrs(a, depth + 1);
                    return x.close(depth, "attrs");
                }
                var attrs: [2]XmlAttr = undefined;
                var n: usize = 0;
                var drv_path: []const u8 = "";
                if (a.get(ev.s.drvPath)) |d| {
                    const dv = try ev.forceCell(&d.cell);
                    if (dv.kind() == .string) {
                        drv_path = dv.as(value.String).bytes();
                        attrs[n] = .{ "drvPath", drv_path };
                        n += 1;
                    }
                }
                if (a.get(ev.s.outPath)) |o| {
                    const ov = try ev.forceCell(&o.cell);
                    if (ov.kind() == .string) {
                        attrs[n] = .{ "outPath", ov.as(value.String).bytes() };
                        n += 1;
                    }
                }
                try x.open(depth, "derivation", attrs[0..n]);
                if (drv_path.len > 0 and !(try x.drvs_seen.getOrPut(ev.gpa, drv_path)).found_existing) {
                    try x.showAttrs(a, depth + 1);
                } else {
                    try x.empty(depth + 1, "repeated", &.{});
                }
                try x.close(depth, "derivation");
            },
            .list => |l| {
                try x.open(depth, "list", &.{});
                for (l.cells()) |*c| try x.printValue(c.get(), depth + 1, pos);
                try x.close(depth, "list");
            },
            .lambda => |l| {
                try x.open(depth, "function", &.{});
                switch (l.lam.param) {
                    .formals => |f| {
                        var attrs: [2]XmlAttr = undefined;
                        var n: usize = 0;
                        if (f.ellipsis) {
                            attrs[n] = .{ "ellipsis", "1" };
                            n += 1;
                        }
                        if (l.lam.arg) |arg| {
                            attrs[n] = .{ "name", ev.interner.name(arg) };
                            n += 1;
                        }
                        try x.open(depth + 1, "attrspat", attrs[0..n]);
                        const fnames = try ev.gpa.alloc([]const u8, f.formals.len);
                        defer ev.gpa.free(fnames);
                        for (f.formals, fnames) |fm, *o| o.* = ev.interner.name(fm.sym);
                        std.mem.sort([]const u8, fnames, {}, bytesLess);
                        for (fnames) |name| try x.empty(depth + 2, "attr", &.{.{ "name", name }});
                        try x.close(depth + 1, "attrspat");
                    },
                    .ident => try x.empty(depth + 1, "varpat", &.{.{ "name", if (l.lam.arg) |a| ev.interner.name(a) else "" }}),
                }
                try x.close(depth, "function");
            },
            .primop, .primop_app => try x.empty(depth, "unevaluated", &.{}),
            .thunk => unreachable,
        }
    }
};

fn bytesLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}
