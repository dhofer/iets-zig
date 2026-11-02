//! The last stage: lines to stdout, with `--constituents` withholding the
//! aggregates until the walk is over (nix-eval-jobs.cc:emitResponse).

const std = @import("std");
const Io = std.Io;
const Writer = Io.Writer;
const Allocator = std.mem.Allocator;
const Diag = @import("../diag.zig").Diag;
const Log = @import("../log.zig").Log;
const jobs_mod = @import("../jobs.zig");
const Error = jobs_mod.Error;
const Stats = jobs_mod.Stats;
const constituents = @import("constituents.zig");
const Line = @import("line.zig").Line;
const Connection = @import("../remote/worker.zig").Connection;

/// Not thread-safe: the caller serializes `emit` and `finish`.
pub const Emitter = struct {
    gpa: Allocator,
    out: *Writer,
    constituents: bool,
    jobs: constituents.Jobs = .{},
    stats: Stats = .{},
    /// A fatal error line was seen: nix-eval-jobs stops with exit 1.
    fatal: bool = false,
    /// The reader closed the pipe (`iets eval-jobs | head`). Nothing more
    /// is written; the frontend stops with exit 0.
    closed: bool = false,

    pub fn init(gpa: Allocator, out: *Writer, constituents_: bool) Emitter {
        return .{ .gpa = gpa, .out = out, .constituents = constituents_ };
    }

    pub fn deinit(e: *Emitter) void {
        e.jobs.deinit(e.gpa);
        e.* = undefined;
    }

    /// Takes `line`, which goes out now or, an aggregate under
    /// `--constituents`, at `finish`.
    pub fn emit(e: *Emitter, line: Line) Allocator.Error!void {
        var l = line;
        defer l.deinit(e.gpa);
        if (e.closed) return;
        switch (l) {
            .job => e.stats.jobs += 1,
            .err => |er| {
                e.stats.errors += 1;
                e.fatal = e.fatal or er.fatal;
            },
        }
        if (!e.constituents) {
            e.closed = !writeLine(e.out, &l);
            return;
        }
        switch (l) {
            .job => |*j| {
                const named = j.named_constituents orelse &.{};
                if (named.len > 0) {
                    const attr = j.attr;
                    const job = j.*;
                    // the entry owns the job now; what is left to free is empty
                    l = .{ .err = .{ .attr = &.{}, .attr_path = &.{}, .message = &.{} } };
                    return e.jobs.put(e.gpa, attr, .{ .drv_path = job.drv_path, .held = job });
                }
                e.closed = !writeLine(e.out, &l);
                try e.jobs.put(e.gpa, j.attr, .{ .drv_path = j.drv_path });
            },
            .err => |*er| {
                e.closed = !writeLine(e.out, &l);
                const message = er.message;
                er.message = &.{};
                try e.jobs.put(e.gpa, er.attr, .{ .message = message });
            },
        }
    }

    /// `--constituents`: resolve and print the withheld aggregates.
    pub fn finish(e: *Emitter, io: Io, conn: *Connection, log: ?*Log, gc_roots_dir: ?[]const u8, d: *Diag) Error!void {
        if (!e.constituents) return;
        return constituents.rewrite(e.gpa, io, &e.jobs, conn, log, gc_roots_dir, .{ .ctx = e, .f = sendOut }, d);
    }

    fn sendOut(ctx: ?*anyopaque, l: *const Line) void {
        const e: *Emitter = @ptrCast(@alignCast(ctx.?));
        if (!e.closed) e.closed = !writeLine(e.out, l);
    }
};

/// `false` once the reader is gone; that ends the run, it is not an error.
/// A `*Writer` reports every failure as `WriteFailed`, so any failure ends
/// it here, though Rust iets tells a broken pipe from the rest.
fn writeLine(out: *Writer, l: *const Line) bool {
    l.render(out) catch return false;
    out.writeByte('\n') catch return false;
    out.flush() catch return false;
    return true;
}

const testing = std.testing;

fn parse(s: []const u8) !Line {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    return Line.parse(testing.allocator, s, &d);
}

const job_a =
    \\{"attr":"a","attrPath":["a"],"constituents":[],"drvPath":"/nix/store/00000000000000000000000000000000-a.drv","globConstituents":false,"outputs":{}}
;
const err_b =
    \\{"attr":"b","attrPath":["b"],"error":"boom","fatal":true}
;
const agg =
    \\{"attr":"agg","attrPath":["agg"],"constituents":[],"drvPath":"/nix/store/00000000000000000000000000000000-agg.drv","globConstituents":false,"namedConstituents":["b"],"outputs":{}}
;

test "lines go out as they come, counted" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var e: Emitter = .init(testing.allocator, &out.writer, false);
    defer e.deinit();
    try e.emit(try parse(job_a));
    try e.emit(try parse(err_b));
    try e.emit(try parse(agg));
    try testing.expectEqualStrings(job_a ++ "\n" ++ err_b ++ "\n" ++ agg ++ "\n", out.written());
    try testing.expectEqual(2, e.stats.jobs);
    try testing.expectEqual(1, e.stats.errors);
    try testing.expect(e.fatal);
    try e.finish(testing.io, undefined, null, null, undefined);
}

test "--constituents withholds the aggregates until finish" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var e: Emitter = .init(testing.allocator, &out.writer, true);
    defer e.deinit();
    try e.emit(try parse(agg));
    try e.emit(try parse(job_a));
    try e.emit(try parse(err_b));
    try testing.expectEqualStrings(job_a ++ "\n" ++ err_b ++ "\n", out.written());
    try testing.expectEqual(2, e.stats.jobs);
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    // a broken constituent needs no store
    try e.finish(testing.io, undefined, null, null, &d);
    const want =
        \\{"attr":"agg","attrPath":["agg"],"constituents":[],"drvPath":"/nix/store/00000000000000000000000000000000-agg.drv","error":"b: boom\n","globConstituents":false,"outputs":{}}
    ;
    try testing.expectEqualStrings(job_a ++ "\n" ++ err_b ++ "\n" ++ want ++ "\n", out.written());
}

test "a closed reader ends the output" {
    var buf: [8]u8 = undefined;
    var out: Writer = .fixed(&buf);
    var e: Emitter = .init(testing.allocator, &out, false);
    defer e.deinit();
    try e.emit(try parse(job_a));
    try testing.expect(e.closed);
    try e.emit(try parse(err_b));
    try testing.expectEqual(1, e.stats.jobs);
    try testing.expectEqual(0, e.stats.errors);
}
