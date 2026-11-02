//! `IETS_STATS=1`: the evaluator's counters and its arena on stderr.
//! The first line is the one Rust iets prints; the kinds below it are
//! iets's own (`Evaluator.Stats.Cat`).

const std = @import("std");
const Evaluator = @import("Evaluator.zig");
const ir = @import("ir.zig");
const value = @import("../runtime/value.zig");

/// The run's figures: the demand path's counters plus what the helpers
/// folded into the pool, and every worker's arena.
pub fn print(ev: *Evaluator) void {
    const st = &ev.stats;
    var thunks = st.thunks;
    var calls = st.calls;
    var store_adds = st.store_adds;
    var compile_ns = st.compile_ns;
    var bytes: u64 = ev.local.arena.used;
    var mapped: u64 = ev.local.arena.mapped;
    if (ev.pool) |p| {
        thunks += p.totals.thunks.load(.monotonic);
        calls += p.totals.calls.load(.monotonic);
        store_adds += p.totals.store_adds.load(.monotonic);
        compile_ns += p.totals.compile_ns.load(.monotonic);
        const u = p.arenaUse();
        bytes = u.bytes;
        mapped = u.mapped;
    }
    const drvs = blk: {
        ev.shared.drv_lock.lock(ev);
        defer ev.shared.drv_lock.unlock(ev);
        break :blk ev.shared.drv.nr_derivations;
    };
    ev.log("files={d} thunks={d} calls={d} drvs={d} store_adds={d} arena_bytes={d} arena_mapped={d} rss_kb={d} compile={f} ir_size={d}", .{
        ev.files.files.items.len, thunks, calls,     drvs,                      store_adds,
        bytes,                    mapped, rssKb(ev), Debug{ .ns = compile_ns }, @sizeOf(ir.Ir),
    });
    var sum: u64 = 0;
    inline for (comptime std.enums.values(Evaluator.Stats.Cat)) |c| {
        const b = st.bytes.get(c);
        sum += b;
        ev.log("  {s:<13} {d:>6} MB", .{ @tagName(c), b >> 20 });
    }
    const flat = value.Union.flat_bytes.load(.monotonic);
    ev.log("  {s:<13} {d:>6} MB", .{ "update-flat", flat >> 20 });
    ev.log("  {s:<13} {d:>6} MB", .{ "other", (ev.local.arena.used -| sum -| flat) >> 20 });
    ev.log("parse {d} ms, parse+compile {d} ms", .{ st.parse_ns / std.time.ns_per_ms, st.compile_ns / std.time.ns_per_ms });
    if (ev.config.ir_cache) |c| ev.log("ir cache: {d} files loaded", .{c.hits.load(.monotonic)});
}

/// Resident set size from `/proc/self/statm`, 0 when it cannot be read.
fn rssKb(ev: *Evaluator) u64 {
    var buf: [128]u8 = undefined;
    const text = std.Io.Dir.cwd().readFile(ev.io, "/proc/self/statm", &buf) catch return 0;
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    _ = it.next() orelse return 0;
    const pages = std.fmt.parseInt(u64, it.next() orelse return 0, 10) catch return 0;
    return pages * 4;
}

/// A duration as Rust's `Debug` for `Duration` prints it: the largest unit
/// with a whole part, its fraction without trailing zeros.
const Debug = struct {
    ns: u64,

    pub fn format(d: Debug, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const units = [_]struct { div: u64, digits: u6, name: []const u8 }{
            .{ .div = std.time.ns_per_s, .digits = 9, .name = "s" },
            .{ .div = std.time.ns_per_ms, .digits = 6, .name = "ms" },
            .{ .div = std.time.ns_per_us, .digits = 3, .name = "µs" },
        };
        for (units) |u| {
            if (d.ns < u.div) continue;
            try w.print("{d}", .{d.ns / u.div});
            var frac = d.ns % u.div;
            if (frac != 0) {
                var digits: usize = u.digits;
                while (frac % 10 == 0) : (digits -= 1) frac /= 10;
                try w.print(".{d:0>[1]}", .{ frac, digits });
            }
            return w.writeAll(u.name);
        }
        try w.print("{d}ns", .{d.ns});
    }
};

test "a duration prints as Rust's Debug" {
    var buf: [32]u8 = undefined;
    const cases = [_]struct { ns: u64, text: []const u8 }{
        .{ .ns = 0, .text = "0ns" },
        .{ .ns = 8270, .text = "8.27µs" },
        .{ .ns = 1_500_000, .text = "1.5ms" },
        .{ .ns = 2_000_000_000, .text = "2s" },
        .{ .ns = 1_000_000_001, .text = "1.000000001s" },
    };
    for (cases) |c| {
        var w: std.Io.Writer = .fixed(&buf);
        try w.print("{f}", .{Debug{ .ns = c.ns }});
        try std.testing.expectEqualStrings(c.text, w.buffered());
    }
}
