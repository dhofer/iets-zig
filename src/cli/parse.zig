//! `iets parse`: the parser run over whole trees.
//!
//! `--chunked` is this port's own: huge sets are parsed in chunks on
//! threads, as the evaluator's workers parse them, so `parse-parity.sh`
//! can check that path against Rust iets's sequential parse.

const std = @import("std");
const Io = std.Io;
const cli = @import("../cli.zig");
const help = @import("help.zig");
const syntax = @import("../syntax.zig");
const Heap = @import("../Heap.zig");
const Session = @import("../session.zig").Session;
const Diag = @import("../diag.zig").Diag;
const Report = @import("../log.zig").Report;
const errors = @import("../errors.zig");

/// What `iets parse` prints for a file that parses.
pub const Form = enum {
    /// S-expressions.
    text,
    /// One `{"file", "root"}` line (docs/reference/syntax-tree.md).
    json,
    /// Nothing; the totals follow the last file.
    quiet,
};

/// `iets parse [-q | --json] [--log-format F] FILE...`; a lone `-` reads
/// the list of files from stdin.
pub fn cmd(c: *const cli.Ctx, argv: []const []const u8) u8 {
    const s = c.s;
    const arena = c.init.arena.allocator();
    var form: Form = .text;
    var chunked = false;
    var names: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const x = argv[i];
        const flag = std.meta.stringToEnum(enum { @"-q", @"--json", @"--chunked", @"--log-format" }, x) orelse {
            if (x.len > 0 and x[0] == '-' and !std.mem.eql(u8, x, "-")) return help.unknownFlag(s, x);
            names.append(arena, x) catch return 1;
            continue;
        };
        switch (flag) {
            .@"-q" => form = .quiet,
            .@"--json" => form = .json,
            .@"--chunked" => chunked = true,
            .@"--log-format" => {
                i += 1;
                if (i >= argv.len) return help.argError(s, "--log-format needs a value");
                var d: Diag = .init(s.gpa);
                defer d.deinit();
                s.log.setFormat(argv[i], &d) catch return help.argError(s, d.message());
            },
        }
    }
    var files = names.items;
    if (files.len == 0) return help.argError(s, "parse needs FILE... or - to read them from stdin");
    if (files.len == 1 and std.mem.eql(u8, files[0], "-")) {
        var buf: [4096]u8 = undefined;
        var r = Io.File.stdin().readerStreaming(s.io, &buf);
        const list = r.interface.allocRemaining(arena, .unlimited) catch "";
        var lines: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, list, '\n');
        while (it.next()) |l| {
            // `str::lines`: a last empty line is none, a `\r\n` ends one
            if (it.index == null and l.len == 0) break;
            lines.append(arena, std.mem.trimEnd(u8, l, "\r")) catch return 1;
        }
        files = lines.items;
    }
    var job: Job = .{ .s = s, .io = c.init.io, .gpa = Heap.allocator, .files = files, .form = form, .chunked = chunked };
    // Deep nesting recurses deeply; the parser gets a big stack.
    const t = std.Thread.spawn(.{ .stack_size = 1 << 30 }, Job.run, .{&job}) catch return 1;
    t.join();
    if (job.failed) |code| return code;
    return if (job.errors > 0) 1 else 0;
}

const Job = struct {
    s: *Session,
    io: Io,
    gpa: std.mem.Allocator,
    files: []const []const u8,
    form: Form,
    chunked: bool,
    errors: usize = 0,
    failed: ?u8 = null,

    fn run(job: *Job) void {
        job.runFallible() catch |e| {
            if (job.failed != null) return;
            job.s.log.errln(@errorName(e));
            job.failed = 1;
        };
    }

    /// With `-q`, parse every file, report errors, and print totals. Used to
    /// check and time the parser on whole trees such as nixpkgs.
    fn runFallible(job: *Job) !void {
        const s = job.s;
        var out: Io.Writer.Allocating = .init(job.gpa);
        defer out.deinit();
        var interner: syntax.Interner = try .init(job.gpa);
        defer interner.deinit();
        var reuse: syntax.Ast = .{};
        defer reuse.deinit(job.gpa);
        var bytes: usize = 0;
        const start = Io.Clock.awake.now(job.io);
        for (job.files, 0..) |file, k| {
            const src = Io.Dir.cwd().readFileAlloc(job.io, file, job.gpa, .unlimited) catch |e| {
                try job.flush(&out);
                var buf: [4200]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "cannot read {s}: {s}", .{ file, errors.ioText(e) }) catch "cannot read a file";
                const r: Report = .{ .code = "io", .raw = msg };
                _ = r.emit(&s.log);
                job.errors += 1;
                continue;
            };
            defer job.gpa.free(src);
            bytes += src.len;
            var d: syntax.Diag = .init(job.gpa);
            defer d.deinit();
            var at: u32 = 0;
            var threads: ThreadPar = .{ .interner = &interner };
            const par: syntax.parser.Parallel = .{ .ctx = &threads, .workers = 4, .run = ThreadPar.run };
            const parsed = syntax.parseParallel(job.gpa, reuse, src, @fromBackingInt(@intCast(k)), &interner, &d, &at, if (job.chunked) &par else null);
            reuse = .{};
            if (parsed) |a| {
                reuse = a;
                switch (job.form) {
                    .quiet => {},
                    .json => try syntax.dump.writeJsonLine(&out.writer, file, &reuse, &interner),
                    .text => {
                        try syntax.dump.writeSexp(&out.writer, &reuse, &interner);
                        try out.writer.writeByte('\n');
                    },
                }
                if (out.written().len >= 1 << 16) try job.flush(&out);
            } else |e| {
                if (e != error.SyntaxError) return e;
                try job.flush(&out);
                const l, const col = syntax.lineCol(src, at);
                var buf: [4200]u8 = undefined;
                const pos = std.fmt.bufPrint(&buf, "{s}:{d}:{d}", .{ file, l, col }) catch file;
                const r: Report = .{ .code = "parse", .raw = d.message(), .pos = pos };
                _ = r.emit(&s.log);
                job.errors += 1;
            }
        }
        try job.flush(&out);
        if (job.form == .quiet) {
            const ns: u64 = @intCast(start.durationTo(Io.Clock.awake.now(job.io)).toNanoseconds());
            var buf: [128]u8 = undefined;
            s.log.err(std.fmt.bufPrint(&buf, "{d} files, {d} bytes, {d} errors, {d:.3}s\n", .{ job.files.len, bytes, job.errors, @as(f64, @floatFromInt(ns)) / 1e9 }) catch "");
        }
    }

    /// Everything printed so far, on stdout.
    fn flush(job: *Job, out: *Io.Writer.Allocating) !void {
        const b = out.written();
        if (b.len == 0) return;
        job.s.out.writeAll(b) catch {
            job.failed = help.writeFailed(job.s, b.len);
            return error.Reported;
        };
        out.clearRetainingCapacity();
    }
};

/// `syntax.parser.Parallel` on one thread per job, each with an interner
/// handle of its own.
const ThreadPar = struct {
    interner: *syntax.Interner,

    fn run(ctx: *anyopaque, n: u32, job_ctx: *anyopaque, job: *const fn (*anyopaque, u32, *syntax.Interner) void) *syntax.Interner {
        const self: *ThreadPar = @ptrCast(@alignCast(ctx));
        const One = struct {
            fn go(i: u32, base: *syntax.Interner, jc: *anyopaque, j: *const fn (*anyopaque, u32, *syntax.Interner) void) void {
                var own = base.fork() catch return;
                defer own.deinit();
                j(jc, i, &own);
            }
        };
        var ts: [64]?std.Thread = @splat(null);
        for (0..n) |i| ts[i] = std.Thread.spawn(.{ .stack_size = 64 << 20 }, One.go, .{ @as(u32, @intCast(i)), self.interner, job_ctx, job }) catch null;
        for (0..n) |i| if (ts[i]) |t| t.join() else One.go(@intCast(i), self.interner, job_ctx, job);
        return self.interner;
    }
};
