//! Error messages for Zig errors. A fallible function that has something to say
//! takes a `*Diag`, writes the message there, and returns the error.

const std = @import("std");

pub const Diag = struct {
    gpa: std.mem.Allocator,
    msg: ?[]u8 = null,
    /// What to do about it, shown as a record's `hint`.
    hint: ?[]u8 = null,

    pub fn init(gpa: std.mem.Allocator) Diag {
        return .{ .gpa = gpa };
    }

    pub fn deinit(d: *Diag) void {
        if (d.msg) |m| d.gpa.free(m);
        d.msg = null;
        if (d.hint) |h| d.gpa.free(h);
        d.hint = null;
    }

    /// Record a message and return `err`, for `return d.fail(error.X, ...)`.
    pub fn fail(d: *Diag, err: anytype, comptime fmt: []const u8, args: anytype) @TypeOf(err) {
        d.deinit();
        d.msg = std.fmt.allocPrint(d.gpa, fmt, args) catch null;
        return err;
    }

    /// `fail`, and the fix for it.
    pub fn failHint(d: *Diag, err: anytype, hint: []const u8, comptime fmt: []const u8, args: anytype) @TypeOf(err) {
        const e = d.fail(err, fmt, args);
        d.hint = d.gpa.dupe(u8, hint) catch null;
        return e;
    }

    pub fn message(d: *const Diag) []const u8 {
        return d.msg orelse "out of memory";
    }
};
