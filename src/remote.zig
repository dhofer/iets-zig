//! Remote builds: the upload plan, the Nix worker-protocol client and the
//! `grpc://` client for nix-grpc-store.
//!
//! Every fallible function here takes a `*Diag` and fails with one of `Error`.

const std = @import("std");
const Diag = @import("diag.zig").Diag;

pub const event = @import("remote/event.zig");
pub const plan = @import("remote/plan.zig");
pub const copy = @import("remote/copy.zig");
pub const worker = @import("remote/worker.zig");
pub const grpc = @import("remote/grpc.zig");
pub const zstd = @import("remote/zstd.zig");

/// The error kinds this layer reports; the message is in the `Diag`.
/// `Io` is a context and the OS's text, `Protocol` malformed data
/// from another process, `Usage` bad input from the user, `Store` a store
/// path, derivation or hash, `Plan` the upload plan.
pub const Error = error{ Io, Protocol, Usage, Store, Plan, OutOfMemory, Canceled };

/// The text of an error a transport meets: `strerror` for an OS error,
/// and the words Rust iets prints for the two that are not.
pub fn ioText(e: anyerror) []const u8 {
    return switch (e) {
        error.EndOfStream => "failed to fill whole buffer",
        error.UnknownHostName => "failed to lookup address information: Name or service not known",
        else => @import("errors.zig").ioText(e),
    };
}

/// `Error::io(context, e)`: "<context>: <strerror>".
pub fn failIo(d: *Diag, e: anyerror, comptime fmt: []const u8, args: anytype) error{Io} {
    return d.fail(error.Io, fmt ++ ": {s}", args ++ .{ioText(e)});
}

/// Puts `<prefix>: ` before the message already in `d`, the way an error
/// wrapped in an outer context prints.
pub fn prefix(d: *Diag, comptime fmt: []const u8, args: anytype) void {
    const old = d.msg orelse return;
    const new = std.fmt.allocPrint(d.gpa, fmt ++ ": {s}", args ++ .{old}) catch return;
    d.gpa.free(old);
    d.msg = new;
}

/// One field of an activity or result, as worker-protocol-connection.cc:readFields
/// gives them: an integer or a string.
pub const Field = union(enum) {
    int: u64,
    string: []const u8,
};

/// The session's log (`log.zig`) as this layer reports into it: the
/// daemon's activities are forwarded, and the gRPC client makes its own.
/// `.none` drops everything.
pub const Log = struct {
    log: ?*L.Log = null,

    const L = @import("log.zig");

    pub const none: Log = .{};

    pub fn of(l: *L.Log) Log {
        return .{ .log = l };
    }

    /// Nix's activities and results carry a handful of fields; a longer
    /// list is cut, which no caller here sends.
    fn convert(fields: []const Field, buf: []L.Field) []const L.Field {
        const n = @min(fields.len, buf.len);
        for (fields[0..n], buf[0..n]) |f, *o| o.* = switch (f) {
            .int => |i| .{ .int = @bitCast(i) },
            .string => |t| .{ .str = t },
        };
        return buf[0..n];
    }

    /// Whether activity records go anywhere.
    pub fn activities(l: Log) bool {
        const log = l.log orelse return false;
        return log.activities();
    }

    /// A fresh activity id, unique in this process.
    pub fn activityId(l: Log) u64 {
        const log = l.log orelse return 0;
        return log.activityId();
    }

    pub fn start(l: Log, id: u64, level: u64, ty: u64, text: []const u8, fields: []const Field, parent: u64) void {
        const log = l.log orelse return;
        var buf: [16]L.Field = undefined;
        log.start(id, level, ty, text, convert(fields, &buf), parent);
    }

    pub fn stop(l: Log, id: u64) void {
        if (l.log) |log| log.stop(id);
    }

    pub fn result(l: Log, id: u64, ty: u64, fields: []const Field) void {
        const log = l.log orelse return;
        var buf: [16]L.Field = undefined;
        log.result(id, ty, convert(fields, &buf));
    }

    /// One line on stderr (Nix's `printError`).
    pub fn errln(l: Log, comptime fmt: []const u8, args: anytype) void {
        const log = l.log orelse return;
        var buf: [4096]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, fmt, args) catch blk: {
            @memcpy(buf[buf.len - 3 ..], "...");
            break :blk &buf;
        };
        log.errln(line);
    }

    /// Starts an activity under `parent`; `Activity.end` stops it.
    pub fn activity(l: Log, parent: u64, level: u64, ty: u64, text: []const u8, fields: []const Field) Activity {
        if (l.log == null) return .{ .log = l, .id = 0 };
        const id = l.activityId();
        l.start(id, level, ty, text, fields, parent);
        return .{ .log = l, .id = id };
    }
};

/// A started activity: it stops when the holder calls `end`.
pub const Activity = struct {
    log: Log,
    id: u64,

    pub fn result(a: Activity, ty: u64, fields: []const Field) void {
        if (a.id != 0) a.log.result(a.id, ty, fields);
    }

    pub fn end(a: Activity) void {
        if (a.id != 0) a.log.stop(a.id);
    }
};

/// The verbosity levels and activity and result types of logging.hh.
pub const lvl_error: u64 = 0;
pub const lvl_info: u64 = 3;
pub const lvl_talkative: u64 = 4;
pub const act_unknown: u64 = 0;
pub const act_copy_path: u64 = 100;
pub const act_realise: u64 = 102;
pub const act_copy_paths: u64 = 103;
pub const act_builds: u64 = 104;
pub const act_build: u64 = 105;
pub const res_build_log_line: u64 = 101;
pub const res_set_phase: u64 = 104;
pub const res_progress: u64 = 105;

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(worker);
    std.testing.refAllDecls(grpc);
}
