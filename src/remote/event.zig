//! What the daemon reports while it builds, decoded from the `STDERR_*` stream.
//!
//! An event's strings are borrowed for the duration of the callback; a
//! receiver that keeps one copies it.

pub const Event = union(enum) {
    started: Started,
    log: Log,
    failed: Failed,
    phase: Phase,
    stopped: Stopped,
};

pub const Started = struct {
    drv_path: []const u8,
};

/// `drv_path` is empty when the daemon did not attribute the line to a build.
pub const Log = struct {
    drv_path: []const u8,
    line: []const u8,
};

pub const Failed = struct {
    drv_path: []const u8,
    reason: []const u8,
};

/// A build's `setPhase` result (logging.hh:resSetPhase).
pub const Phase = struct {
    drv_path: []const u8,
    phase: []const u8,
};

/// The build activity ended. `built` is true when the backend saw the build
/// succeed. False says nothing, the op's `BuildResult` and the daemon's error
/// messages decide.
pub const Stopped = struct {
    drv_path: []const u8,
    built: bool,
};

/// Where a connection sends its events: a callback and its context.
pub const Sink = struct {
    ctx: ?*anyopaque = null,
    f: ?*const fn (ctx: ?*anyopaque, e: Event) void = null,

    /// Drops every event.
    pub const ignore: Sink = .{};

    pub fn send(s: Sink, e: Event) void {
        if (s.f) |f| f(s.ctx, e);
    }

    /// A sink calling `T.onEvent(ctx, e)`.
    pub fn of(comptime T: type, ctx: *T) Sink {
        return .{ .ctx = ctx, .f = struct {
            fn f(c: ?*anyopaque, e: Event) void {
                T.onEvent(@ptrCast(@alignCast(c.?)), e);
            }
        }.f };
    }
};
