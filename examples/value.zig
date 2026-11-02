//! Walk a value with the value API.
//!
//! `zig build example-value && zig-out/bin/value [-E EXPR]`
//!
//! Uses the library only (`iets.api.value`), never `iets.cli`. Ported from
//! ../iets/examples/value.rs.

const std = @import("std");
const iets = @import("iets");
const api = iets.api;
const value = api.value;
const Eval = value.Eval;
const Value = value.Value;

const default =
    \\
    \\  rec {
    \\    name = "demo";
    \\    version = 3;
    \\    ratio = 0.5;
    \\    enabled = true;
    \\    nothing = null;
    \\    dir = /tmp;
    \\    tags = [ "one" "two" ];
    \\    greet = who: "hello ${who}";
    \\    nested = { inherit name; };
    \\  }
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    // a frontend owns the run state and says where messages go
    const s = try iets.session.Session.create(init.gpa, init.io, .process(init.environ_map));
    defer s.destroy();
    var stderr: iets.sys.fs.FdWriter = .{ .fd = 2 };
    s.log.writeTo(&stderr.interface);
    // before the first store path is made
    try api.initStoreDir(s, arena);

    const argv = try init.minimal.args.toSlice(arena);
    const src: []const u8 = if (argv.len < 2) default else if (std.mem.eql(u8, argv[1], "-E") or std.mem.eql(u8, argv[1], "--expr")) blk: {
        if (argv.len < 3) return die(&stderr.interface, "-E needs an EXPR", .{});
        break :blk argv[2];
    } else return die(&stderr.interface, "unknown flag {s}", .{argv[1]});

    // impure, with no project root: a host has no command line and no entry file
    const inst = try api.Instance.create(init.gpa, init.io, .{ .session = s });
    defer inst.destroy();
    const e: Eval = .init(&inst.ev);
    var buf: [4096]u8 = undefined;
    var stdout: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const root = e.force(e.evalExpr(src, "/") catch return report(e, s, arena)) catch return report(e, s, arena);
    try out.print("root is {s}\n", .{root.kind().typeOf()});
    const n = root.attrsLen() orelse return 0;

    // index order is the evaluator's own, so sort for a stable listing
    const names = try arena.alloc([]const u8, n);
    for (names, 0..) |*name, i| name.* = (try e.attrAt(root, i)).?.name;
    std.mem.sort([]const u8, names, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);

    for (names) |name| {
        const v = e.force((try e.attr(root, name)).?) catch {
            try out.flush();
            return report(e, s, arena);
        };
        try out.print("  {s} : {s} = ", .{ name, v.kind().typeOf() });
        try showValue(out, v);
        try out.writeByte('\n');
    }

    // read a field by name, then call the function value with an argument
    if (e.attr(root, "version") catch null) |v0| if (e.force(v0) catch null) |v| {
        if (v.asInt()) |x| try out.print("version + 0 = Some({d})\n", .{x}) else try out.writeAll("version + 0 = None\n");
    };
    if (e.attr(root, "greet") catch null) |f0| if (e.force(f0) catch null) |f| {
        const r = e.call(f, try e.string("world")) catch null;
        if (if (r) |x| e.force(x) catch null else null) |x| {
            try out.writeAll("greet \"world\" = ");
            try showValue(out, x);
            try out.writeByte('\n');
        } else {
            try out.flush();
            _ = try report(e, s, arena);
        }
    };
    return 0;
}

fn report(e: Eval, s: *iets.session.Session, arena: std.mem.Allocator) !u8 {
    _ = try api.report(e.evaluator(), s, arena);
    return 1;
}

fn showValue(w: *std.Io.Writer, v: Value) !void {
    switch (v.kind()) {
        .int => try w.print("{d}", .{v.asInt().?}),
        .float => try w.print("{d}", .{v.asFloat().?}),
        .bool => try w.print("{}", .{v.asBool().?}),
        .null => try w.writeAll("null"),
        .path => try w.writeAll(v.asPath().?),
        .string => {
            try w.print("\"{s}\"", .{v.asBytes().?});
            var ctx = v.context();
            while (ctx.next()) |c| try w.print(" [{s}]", .{c.path()});
        },
        .list => try w.print("{d} elements", .{v.listLen().?}),
        .attrs => try w.print("{d} attributes", .{v.attrsLen().?}),
        .function, .thunk => try w.writeAll(v.kind().typeOf()),
    }
}

fn die(w: *std.Io.Writer, comptime fmt: []const u8, args: anytype) u8 {
    w.print("usage: value [-E EXPR]: " ++ fmt ++ "\n", args) catch {};
    return 2;
}
