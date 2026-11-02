//! Where a run's results go: the process's stdout unless a host redirects
//! it.

const std = @import("std");
const sys = @import("sys.zig");

pub const Stdout = struct {
    io: std.Io,
    lock: std.Io.Mutex = .init,
    /// A host's writer; null is file descriptor 1.
    w: ?*std.Io.Writer = null,
    /// Why the last write to file descriptor 1 failed, for the report:
    /// `.NOSPC` for a full disk.
    failure: std.os.linux.E = .SUCCESS,

    pub fn writeTo(s: *Stdout, w: *std.Io.Writer) void {
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        s.w = w;
    }

    pub fn writeAll(s: *Stdout, b: []const u8) !void {
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        if (s.w) |w| {
            try w.writeAll(b);
            return w.flush();
        }
        var rest = b;
        const linux = std.os.linux;
        while (rest.len > 0) {
            const rc = linux.write(1, rest.ptr, rest.len);
            switch (linux.errno(rc)) {
                .SUCCESS => rest = rest[rc..],
                .INTR, .AGAIN => {},
                else => |e| {
                    s.failure = e;
                    return error.WriteFailed;
                },
            }
        }
    }

    pub fn isTerminal(s: *Stdout) bool {
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        return s.w == null and sys.tty.isTerminal(1);
    }
};

test "a host's writer gets the results" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    var s: Stdout = .{ .io = std.testing.io };
    s.writeTo(&buf.writer);
    try s.writeAll("1\n");
    try std.testing.expectEqualStrings("1\n", buf.written());
    try std.testing.expect(!s.isTerminal());
}
