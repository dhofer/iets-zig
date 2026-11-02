//! A stand-in for `iets parse [--json] FILE...` (or `--list FILE` for a file
//! of paths; `-q` only parses), for diffing this parser against the Rust one:
//!
//!   zig run -O ReleaseFast --dep syntax -Mroot=src/syntax/parity.zig \
//!     -Msyntax=src/syntax.zig -- [--json] FILE...
//!
//! Parse errors go to stderr as `iets parse` prints them.

const std = @import("std");
const syntax = @import("syntax");

const Job = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    files: []const []const u8,
    json: bool,
    quiet: bool,
    errors: usize = 0,
    failed: ?anyerror = null,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var files: std.ArrayList([]const u8) = .empty;
    var json = false;
    var quiet = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, a, "-q")) {
            quiet = true;
        } else if (std.mem.eql(u8, a, "--list")) {
            i += 1;
            const list = try std.Io.Dir.cwd().readFileAlloc(io, args[i], init.arena.allocator(), .unlimited);
            var it = std.mem.tokenizeScalar(u8, list, '\n');
            while (it.next()) |l| try files.append(init.arena.allocator(), l);
        } else try files.append(init.arena.allocator(), a);
    }
    var job: Job = .{ .io = io, .gpa = gpa, .files = files.items, .json = json, .quiet = quiet };
    // deep nesting recurses deeply; the Rust binary parses on a big stack too
    const t = try std.Thread.spawn(.{ .stack_size = 1 << 30 }, run, .{&job});
    t.join();
    if (job.failed) |e| return e;
    if (job.errors > 0) std.process.exit(1);
}

fn run(job: *Job) void {
    runFallible(job) catch |e| {
        job.failed = e;
    };
}

fn runFallible(job: *Job) !void {
    const io = job.io;
    const gpa = job.gpa;
    var out_buf: [1 << 16]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &out_buf);
    var err_buf: [4096]u8 = undefined;
    var err = std.Io.File.stderr().writer(io, &err_buf);
    var interner: syntax.Interner = try .init(gpa);
    defer interner.deinit();
    var reuse: syntax.Ast = .{};
    defer reuse.deinit(gpa);
    for (job.files, 0..) |file, k| {
        const src = std.Io.Dir.cwd().readFileAlloc(io, file, gpa, .unlimited) catch |e| {
            try err.interface.print("error: cannot read {s}: {t}\n", .{ file, e });
            job.errors += 1;
            continue;
        };
        defer gpa.free(src);
        var d: syntax.Diag = .init(gpa);
        defer d.deinit();
        var at: u32 = 0;
        const parsed = syntax.parseReusing(gpa, reuse, src, @fromBackingInt(@intCast(k)), &interner, &d, &at);
        reuse = .{};
        if (parsed) |a| {
            reuse = a;
            if (job.quiet) {} else if (job.json) {
                try syntax.dump.writeJsonLine(&out.interface, file, &reuse, &interner);
            } else {
                try syntax.dump.writeSexp(&out.interface, &reuse, &interner);
                try out.interface.writeByte('\n');
            }
        } else |e| {
            if (e != error.SyntaxError) return e;
            const l, const c = syntax.lineCol(src, at);
            try out.interface.flush();
            try err.interface.print("error: {s}\n       at {s}:{d}:{d}\n", .{ d.message(), file, l, c });
            try err.interface.flush();
            job.errors += 1;
        }
    }
    try out.interface.flush();
    try err.interface.flush();
}
