//! Evaluate an expression or a file and print it as strict JSON.
//!
//! `zig build example-eval && zig-out/bin/eval [-I prefix=path]... [-A attr] (-E EXPR | FILE)`
//!
//! Uses the library only (`iets.api`), never `iets.cli`. Ported from
//! ../iets/examples/eval.rs.

const std = @import("std");
const iets = @import("iets");
const api = iets.api;
const Evaluator = iets.eval.Evaluator;

const usage = "usage: eval [-I prefix=path]... [-A attr] [--workers N] (-E EXPR | FILE)";

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    // a frontend owns the run state and says where messages go
    const s = try iets.session.Session.create(init.gpa, init.io, .process(init.environ_map));
    defer s.destroy();
    var stderr: iets.sys.fs.FdWriter = .{ .fd = 2 };
    s.log.writeTo(&stderr.interface);
    // before the first store path is made
    try api.initStoreDir(s, arena);

    var a: api.EvalArgs = .{ .strict = true, .json = true };
    var includes: std.ArrayList([]const u8) = .empty;
    const argv = try init.minimal.args.toSlice(arena);
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (is(arg, "-I", "--include") or is(arg, "-E", "--expr") or is(arg, "-A", "--attr") or is(arg, "--workers", "--workers")) {
            i += 1;
            if (i >= argv.len) return die(&stderr.interface, "{s} needs a value", .{arg});
            const v = argv[i];
            if (is(arg, "-I", "--include")) {
                try includes.append(arena, v);
            } else if (is(arg, "-E", "--expr")) {
                a.input = .{ .expr = v };
            } else if (is(arg, "-A", "--attr")) {
                a.attr = v;
            } else a.workers = std.fmt.parseInt(u32, v, 10) catch return die(&stderr.interface, "--workers N", .{});
        } else if (arg.len > 1 and arg[0] == '-') {
            return die(&stderr.interface, "unknown flag {s}", .{arg});
        } else a.input = .{ .file = arg };
    }
    a.includes = includes.items;
    if (a.input == null) return die(&stderr.interface, "give -E EXPR or a FILE", .{});

    // The evaluator runs as the main fiber of the parallel runtime; with one
    // worker `go` is a plain call. An evaluation error is reported by `go`.
    const run: api.run.Run = .{ .s = s, .init = &init, .args = &a, .keep_site = false };
    return run.go(&run, struct {
        fn go(r: *const api.run.Run, ev: *Evaluator) anyerror!u8 {
            const a_ = r.init.arena.allocator();
            const v = try api.evaluate(ev, a_, r.args, try r.cwd());
            var buf: [65536]u8 = undefined;
            var out: std.Io.File.Writer = .initStreaming(.stdout(), r.init.io, &buf);
            var ctx: std.ArrayList(iets.runtime.value.Ctx) = .empty;
            defer ctx.deinit(ev.gpa);
            iets.eval.print.writeJson(ev, &out.interface, v, &ctx, true, .none) catch |e| return switch (e) {
                error.WriteFailed => out.err orelse e,
                else => e,
            };
            try out.interface.writeByte('\n');
            try out.interface.flush();
            return 0;
        }
    }.go);
}

fn is(arg: []const u8, short: []const u8, long: []const u8) bool {
    return std.mem.eql(u8, arg, short) or std.mem.eql(u8, arg, long);
}

fn die(w: *std.Io.Writer, comptime fmt: []const u8, args: anytype) u8 {
    w.print(usage ++ ": " ++ fmt ++ "\n", args) catch {};
    return 2;
}
