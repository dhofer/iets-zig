//! List the derivations an evaluation created, with the attribute path and
//! the source position each came from (docs/explanation/provenance.md).
//!
//! `zig build example-drv_info && zig-out/bin/drv_info [-I prefix=path]... [-A attr] (-E EXPR | FILE)`
//!
//! Uses the library only (`iets.api`), never `iets.cli`. Ported from
//! ../iets/examples/drv_info.rs.

const std = @import("std");
const iets = @import("iets");
const api = iets.api;
const Evaluator = iets.eval.Evaluator;

const usage = "usage: drv_info [-I prefix=path]... [-A attr] (-E EXPR | FILE)";

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    // a frontend owns the run state and says where messages go
    const s = try iets.session.Session.create(init.gpa, init.io, .process(init.environ_map));
    defer s.destroy();
    var stderr: iets.sys.fs.FdWriter = .{ .fd = 2 };
    s.log.writeTo(&stderr.interface);
    // before the first store path is made
    try api.initStoreDir(s, arena);

    var a: api.EvalArgs = .{};
    var includes: std.ArrayList([]const u8) = .empty;
    const argv = try init.minimal.args.toSlice(arena);
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (is(arg, "-I", "--include") or is(arg, "-E", "--expr") or is(arg, "-A", "--attr")) {
            i += 1;
            if (i >= argv.len) return die(&stderr.interface, "{s} needs a value", .{arg});
            const v = argv[i];
            if (is(arg, "-I", "--include")) {
                try includes.append(arena, v);
            } else if (is(arg, "-E", "--expr")) {
                a.input = .{ .expr = v };
            } else a.attr = v;
        } else if (arg.len > 1 and arg[0] == '-') {
            return die(&stderr.interface, "unknown flag {s}", .{arg});
        } else a.input = .{ .file = arg };
    }
    a.includes = includes.items;
    if (a.input == null) return die(&stderr.interface, "give -E EXPR or a FILE", .{});

    // `keep_site` records where each derivation was defined
    const run: api.run.Run = .{ .s = s, .init = &init, .args = &a, .keep_site = true };
    return run.go(&run, list);
}

fn list(r: *const api.run.Run, ev: *Evaluator) anyerror!u8 {
    const arena = r.init.arena.allocator();
    // A derivation exists once its attrset is forced, so walk deeply.
    const v = try ev.forceDeep(try api.evaluate(ev, arena, r.args, try r.cwd()));
    // The attribute path a frontend reached a drv by is provenance the
    // evaluator cannot know: the walk records it.
    if (r.args.attr) |t| {
        var roots: std.ArrayList(api.installable.DrvRoot) = .empty;
        if (api.installable.drvRoots(ev, arena, v, &roots)) {
            for (roots.items) |root| try iets.builtins.derivation.setAttr(ev, root.drv.baseName(), t);
        } else |_| ev.clearFailure();
    }
    const s = r.s;
    var map: ?iets.provenance.SourceMap = if (s.settings.provenance) try .fromEval(arena, ev, s.settings.source_map) else null;
    defer if (map) |*m| m.deinit();
    const m: ?*const iets.provenance.SourceMap = if (map) |*x| x else null;

    var rows: std.ArrayList([]const u8) = .empty;
    {
        ev.shared.drv_lock.lock(ev.io);
        defer ev.shared.drv_lock.unlock(ev.io);
        var it = ev.shared.drv.table.iterator();
        while (it.next()) |e| {
            const info = e.value_ptr.*;
            const pos = if (info.site == .none) "-" else try iets.provenance.errorPos(arena, ev, m, info.site);
            const outs = try std.mem.join(arena, ",", info.outputs);
            try rows.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}\t{s}\t{s}\t{s}", .{ iets.store.path.store_dir, e.key_ptr.*, info.attr orelse "-", pos, outs }));
        }
    }
    std.mem.sort([]const u8, rows.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    var buf: [65536]u8 = undefined;
    var stdout: std.Io.File.Writer = .initStreaming(.stdout(), r.init.io, &buf);
    const out = &stdout.interface;
    try out.writeAll("drv\tattr\tposition\toutputs\n");
    for (rows.items) |row| try out.print("{s}\n", .{row});
    try out.flush();
    s.log.errln(try std.fmt.allocPrint(arena, "{d} derivations", .{rows.items.len}));
    return 0;
}

fn is(arg: []const u8, short: []const u8, long: []const u8) bool {
    return std.mem.eql(u8, arg, short) or std.mem.eql(u8, arg, long);
}

fn die(w: *std.Io.Writer, comptime fmt: []const u8, args: anytype) u8 {
    w.print(usage ++ ": " ++ fmt ++ "\n", args) catch {};
    return 2;
}
