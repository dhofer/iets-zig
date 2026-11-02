//! What the dispatcher reports per attribute, for the terminal or CI
//! renderer.
//!
//! An event's strings are borrowed for the duration of the call that takes
//! it; the renderer copies what it keeps.

const std = @import("std");
const ns_per_s = std.time.ns_per_s;

/// One output of a build: its name and store path.
pub const Output = struct {
    name: []const u8,
    path: []const u8,
};

/// A state change of one attribute's build.
pub const Kind = union(enum) {
    /// The builder started. Its phase is unknown until the build says.
    started,
    phase: []const u8,
    /// One line of build output, already attributed to this build.
    log: []const u8,
    built: struct {
        /// Sorted by output name.
        outputs: []const Output = &.{},
    },
    failed: struct {
        reason: []const u8,
        /// The last `render.failure_tail` lines of the build's own log.
        log_tail: []const []const u8 = &.{},
    },
    skipped: struct {
        why: []const u8,
    },
};

/// One event about one attribute.
pub const BuildEvent = struct {
    /// The attribute path plus the source position when it is known, or the
    /// derivation name for a build the dispatcher was not asked for by name
    /// (a dependency).
    attr: []const u8,
    drv: []const u8,
    kind: Kind,
    /// Since this build started, or since the run started for an event that
    /// belongs to no build, in nanoseconds.
    elapsed: u64,
    /// `file:line:col` of the `derivation` call, for the failure line.
    pos: ?[]const u8 = null,

    pub fn init(attr: []const u8, drv: []const u8, kind: Kind, elapsed: u64) BuildEvent {
        return .{ .attr = attr, .drv = drv, .kind = kind, .elapsed = elapsed };
    }
};

/// A duration as the renderer prints it: `2s`, `3m04s`, `1h02m03s`, for `{f}`.
pub const Duration = struct {
    ns: u64,

    pub fn format(d: Duration, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const total = d.ns / ns_per_s;
        const h = total / 3600;
        const m = (total / 60) % 60;
        const s = total % 60;
        if (h > 0) return w.print("{d}h{d:0>2}m{d:0>2}s", .{ h, m, s });
        if (m > 0) return w.print("{d}m{d:0>2}s", .{ m, s });
        return w.print("{d}s", .{s});
    }
};

test "durations" {
    var buf: [32]u8 = undefined;
    const t = std.testing;
    try t.expectEqualStrings("9s", try std.fmt.bufPrint(&buf, "{f}", .{Duration{ .ns = 9 * ns_per_s }}));
    try t.expectEqualStrings("1m10s", try std.fmt.bufPrint(&buf, "{f}", .{Duration{ .ns = 70 * ns_per_s }}));
    try t.expectEqualStrings("1h01m11s", try std.fmt.bufPrint(&buf, "{f}", .{Duration{ .ns = 3671 * ns_per_s }}));
}
