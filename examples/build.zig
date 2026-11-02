//! Evaluate to derivations, plan the upload, build through the dispatcher,
//! print the output paths.
//!
//! `zig build example-build && zig-out/bin/build [--builder URL] [-I prefix=path]... [-A attr] (-E EXPR | FILE)`
//!
//! Uses the library only (`iets.api`), never `iets.cli`. Ported from
//! ../iets/examples/build.rs.

const std = @import("std");
const iets = @import("iets");
const api = iets.api;
const Evaluator = iets.eval.Evaluator;
const StorePath = iets.store.path.StorePath;
const worker = iets.remote.worker;

const usage = "usage: build [--builder URL] [-I prefix=path]... [-A attr] (-E EXPR | FILE)";

const Ctx = struct { r: *const api.run.Run, url: []const u8 };

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    // a frontend owns the run state and says where messages go
    const s = try iets.session.Session.create(init.gpa, init.io, .process(init.environ_map));
    defer s.destroy();
    var stderr: iets.sys.fs.FdWriter = .{ .fd = 2 };
    s.log.writeTo(&stderr.interface);
    // before the first store path is made
    try api.initStoreDir(s, arena);

    var url: []const u8 = "daemon";
    var a: api.EvalArgs = .{};
    var includes: std.ArrayList([]const u8) = .empty;
    const argv = try init.minimal.args.toSlice(arena);
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (is(arg, "--builder", "--builder") or is(arg, "-I", "--include") or is(arg, "-E", "--expr") or is(arg, "-A", "--attr")) {
            i += 1;
            if (i >= argv.len) return die(&stderr.interface, "{s} needs a value", .{arg});
            const v = argv[i];
            if (is(arg, "--builder", "--builder")) {
                url = v;
            } else if (is(arg, "-I", "--include")) {
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

    const run: api.run.Run = .{ .s = s, .init = &init, .args = &a };
    return run.go(Ctx{ .r = &run, .url = url }, evalAndBuild);
}

fn evalAndBuild(c: Ctx, ev: *Evaluator) anyerror!u8 {
    const r = c.r;
    const s = r.s;
    const arena = r.init.arena.allocator();
    var roots: std.ArrayList(api.installable.DrvRoot) = .empty;
    try api.installable.drvRoots(ev, arena, try api.evaluate(ev, arena, r.args, try r.cwd()), &roots);
    // `--out` would add wanted outputs; the roots' string context is enough here.
    const t = try api.buildTargets(arena, &.{}, roots.items);
    var prov = try api.build.snapshot(s, arena, ev);
    defer prov.deinit();

    // Every derivation and source this evaluation created, straight from
    // memory: the plan reads `/nix/store` only for what it did not create.
    var inputs: api.build.EvalInputs = .init(ev);
    defer inputs.deinit();
    var d: iets.diag.Diag = .init(s.gpa);
    defer d.deinit();
    var plan = iets.remote.plan.plan(s.gpa, s.io, t.paths, inputs.inputs(), &d) catch |e| return fail(s, &d, e);
    // the dispatch takes the plan over once it is open
    var owned = true;
    defer if (owned) plan.deinit();
    const env = r.init.environ_map;
    const transport = try arena.create(worker.Transport);
    transport.* = worker.Transport.parse(arena, c.url, env) orelse {
        s.log.errln(try std.fmt.allocPrint(arena, "error: unsupported builder '{s}'", .{c.url}));
        return 2;
    };
    var x = api.build.Dispatch.open(s, env, transport, .default(), plan, &prov, .detect(&s.log), &d) catch |e| return fail(s, &d, e);
    owned = false;
    defer x.deinit();
    const targets = try arena.alloc(iets.build.dispatch.Target, t.paths.len);
    for (t.paths, targets) |p, *tg| tg.* = .{ .attr = p.name(), .drv = p, .outputs = t.outputs };
    const outcomes = x.submit(targets, &d) catch |e| return fail(s, &d, e);

    var buf: [4096]u8 = undefined;
    var stdout: std.Io.File.Writer = .initStreaming(.stdout(), r.init.io, &buf);
    const out = &stdout.interface;
    for (outcomes) |o| for (o.outputs) |op| try out.print("{s}\n", .{op.path});
    try out.flush();
    return @intCast(x.d.exit);
}

/// An error outside the evaluator, as `error: MSG`.
fn fail(s: *iets.session.Session, d: *const iets.diag.Diag, e: anyerror) u8 {
    const rep: iets.log.Report = .{ .code = iets.errors.code(e), .raw = d.message() };
    _ = rep.emit(&s.log);
    return 1;
}

fn is(arg: []const u8, short: []const u8, long: []const u8) bool {
    return std.mem.eql(u8, arg, short) or std.mem.eql(u8, arg, long);
}

fn die(w: *std.Io.Writer, comptime fmt: []const u8, args: anytype) u8 {
    w.print(usage ++ ": " ++ fmt ++ "\n", args) catch {};
    return 2;
}
