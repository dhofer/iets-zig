//! Timing harness for the NAR code (docs/explanation/transports.md).
//!
//! `zig build -Doptimize=ReleaseFast example-nar_bench && zig-out/bin/nar_bench <op> <path> [runs]`
//!
//! Ops: `hash` (NAR hash of a path), `flat` (flat hash of one file), `dump`
//! (NAR to nowhere), `parse` (walk a NAR's framing, contents thrown away:
//! the parser on its own), `restore` (read a NAR from stdin into a fresh
//! directory under the path given). Prints one `op path runs best_ms mean_ms
//! MB/s` line so `bench/nar.nu` can parse it. Ported from
//! ../iets/examples/nar_bench.rs.

const std = @import("std");
const iets = @import("iets");
const nar = iets.store.nar;
const Io = std.Io;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    var stderr: iets.sys.fs.FdWriter = .{ .fd = 2 };
    const err = &stderr.interface;
    if (argv.len < 3) return die(err, "usage: nar_bench <hash|flat|dump|parse|restore> <path> [runs]", .{});
    const op = argv[1];
    const path = argv[2];
    const runs: u32 = if (argv.len > 3) std.fmt.parseInt(u32, argv[3], 10) catch return die(err, "bad run count", .{}) else 3;

    var buf: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .initStreaming(.stdout(), io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};
    var d: iets.diag.Diag = .init(gpa);
    defer d.deinit();
    const cwd = Io.Dir.cwd();

    const times = try init.arena.allocator().alloc(f64, runs);
    var bytes: u64 = 0;
    for (times, 0..) |*t, i| {
        const t0 = Io.Clock.awake.now(io);
        if (std.mem.eql(u8, op, "hash")) {
            const r = nar.narHashFiltered(gpa, io, cwd, path, .sha256, nar.keep_all, &d) catch return fail(err, &d);
            if (i == 0) {
                try out.writeAll("# ");
                try r.hash.write(out, .sri, false);
                try out.print(" {d}\n", .{r.size});
            }
            bytes = r.size;
        } else if (std.mem.eql(u8, op, "flat")) {
            const h = nar.flatHash(io, cwd, path, .sha256, &d) catch return fail(err, &d);
            if (i == 0) {
                try out.writeAll("# ");
                try h.write(out, .sri, false);
                try out.writeByte('\n');
            }
            bytes = if (cwd.statFile(io, path, .{})) |st| st.size else |_| 0;
        } else if (std.mem.eql(u8, op, "dump")) {
            var sink_buf: [1 << 16]u8 = undefined;
            var sink: Io.Writer.Discarding = .init(&sink_buf);
            nar.dumpPath(gpa, io, cwd, path, &sink.writer, nar.keep_all, &d) catch return fail(err, &d);
            bytes = sink.fullCount();
        } else if (std.mem.eql(u8, op, "parse")) {
            const f = cwd.openFile(io, path, .{}) catch |e| return die(err, "{s}: {t}", .{ path, e });
            defer f.close(io);
            var rbuf: [1 << 16]u8 = undefined;
            var fr = f.readerStreaming(io, &rbuf);
            const n = nar.parseLength(&fr.interface, &d) catch return fail(err, &d);
            if (i == 0) try out.print("# parsed {d} bytes\n", .{n});
            bytes = n;
        } else if (std.mem.eql(u8, op, "restore")) {
            if (runs != 1) return die(err, "restore takes one run", .{});
            const dest = try std.fs.path.join(init.arena.allocator(), &.{ path, "restored" });
            cwd.deleteTree(io, dest) catch {};
            var rbuf: [1 << 16]u8 = undefined;
            var in = Io.File.stdin().readerStreaming(io, &rbuf);
            nar.restorePath(io, &in.interface, cwd, dest, &d) catch return fail(err, &d);
            bytes = 0;
        } else return die(err, "unknown op", .{});
        t.* = @as(f64, @floatFromInt(t0.durationTo(Io.Clock.awake.now(io)).nanoseconds)) / 1e9;
    }
    var best = std.math.inf(f64);
    var sum: f64 = 0;
    for (times) |t| {
        best = @min(best, t);
        sum += t;
    }
    const mean = sum / @as(f64, @floatFromInt(times.len));
    const mbs = if (best > 0) @as(f64, @floatFromInt(bytes)) / best / 1e6 else 0;
    try out.print("{s} {s} {d} {d:.1} {d:.1} {d:.0}\n", .{ op, path, runs, best * 1e3, mean * 1e3, mbs });
    return 0;
}

fn fail(w: *std.Io.Writer, d: *const iets.diag.Diag) u8 {
    return die(w, "{s}", .{d.message()});
}

fn die(w: *std.Io.Writer, comptime fmt: []const u8, args: anytype) u8 {
    w.print("nar_bench: " ++ fmt ++ "\n", args) catch {};
    return 2;
}
