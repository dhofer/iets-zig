//! The terminal and the user behind it. Linux only (Windows is not
//! supported). Raw syscalls, not `std.Io`: a signal
//! handler and the log's lock both call in here.

const std = @import("std");
const linux = std.os.linux;

/// Columns and rows of stderr's terminal, if it has one.
pub fn size() ?[2]usize {
    var ws: std.posix.winsize = undefined;
    const rc = linux.ioctl(2, linux.T.IOCGWINSZ, @intFromPtr(&ws));
    if (linux.errno(rc) != .SUCCESS) return null;
    if (ws.col <= 1 or ws.row <= 1) return null;
    return .{ ws.col, ws.row };
}

pub fn isTerminal(fd: linux.fd_t) bool {
    var t: linux.termios = undefined;
    return linux.errno(linux.tcgetattr(fd, &t)) == .SUCCESS;
}

/// Row and column, counted from 1, of stderr's cursor. Asks the terminal
/// through stdin, which needs both to be terminals. A terminal that does not
/// answer in a fifth of a second is taken for one that cannot.
pub fn cursor() ?[2]usize {
    if (!isTerminal(0) or !isTerminal(2)) return null;
    var saved: linux.termios = undefined;
    if (linux.errno(linux.tcgetattr(0, &saved)) != .SUCCESS) return null;
    var raw = saved;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.cc[@backingInt(linux.V.MIN)] = 0;
    raw.cc[@backingInt(linux.V.TIME)] = 2;
    if (linux.errno(linux.tcsetattr(0, .NOW, &raw)) != .SUCCESS) return null;
    var reply: [64]u8 = undefined;
    var n: usize = 0;
    const ask = "\x1b[6n";
    if (linux.errno(linux.write(2, ask, ask.len)) == .SUCCESS) {
        while (n < 32 and (n == 0 or reply[n - 1] != 'R')) {
            const rc = linux.read(0, reply[n..].ptr, 32);
            if (linux.errno(rc) != .SUCCESS or rc == 0) break;
            n += rc;
        }
    }
    _ = linux.tcsetattr(0, .NOW, &saved);
    return parseCursor(reply[0..n]);
}

/// `ESC [ row ; col R`, the last such answer in `reply`.
fn parseCursor(reply: []const u8) ?[2]usize {
    const at = std.mem.lastIndexOf(u8, reply, "\x1b[") orelse return null;
    const body = reply[at + 2 ..];
    if (body.len == 0 or body[body.len - 1] != 'R') return null;
    const semi = std.mem.indexOfScalar(u8, body, ';') orelse return null;
    const row = std.fmt.parseInt(usize, body[0..semi], 10) catch return null;
    const col = std.fmt.parseInt(usize, body[semi + 1 .. body.len - 1], 10) catch return null;
    return .{ row, col };
}

/// The row where the live region starts, or 0 for none. A signal that ends
/// the process takes the region down first, or the shell is left with a
/// scroll margin and no cursor.
var region_top: std.atomic.Value(usize) = .init(0);
var installed: std.atomic.Value(bool) = .init(false);

pub fn guardRegion(top: usize) void {
    region_top.store(top, .monotonic);
    if (top == 0 or installed.swap(true, .monotonic)) return;
    for ([_]linux.SIG{ .INT, .TERM, .HUP }) |sig| {
        var old: linux.Sigaction = undefined;
        const act: linux.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = linux.sigemptyset(), .flags = 0 };
        _ = linux.sigaction(sig, &act, &old);
        // A handler somebody else installed stays.
        if (old.handler.handler != linux.SIG.DFL) _ = linux.sigaction(sig, &old, null);
    }
}

fn onSignal(sig: linux.SIG) callconv(.c) void {
    const top = region_top.load(.monotonic);
    if (top > 0) {
        var buf: [48]u8 = undefined;
        const s = regionReset(&buf, top);
        _ = linux.write(2, s.ptr, s.len);
    }
    // Back to the default action and the signal again, so the exit status
    // is the one the shell expects.
    const dfl: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.DFL }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(sig, &dfl, null);
    _ = linux.tkill(linux.gettid(), sig);
}

/// What takes the region at `top` down: no allocation, for a handler.
fn regionReset(buf: []u8, top: usize) []const u8 {
    return std.fmt.bufPrint(buf, "\x1b[r\x1b[{d};1H\x1b[J\x1b[?25h", .{top}) catch buf[0..0];
}

pub fn isRoot() bool {
    return linux.getuid() == 0;
}

/// Puts SIGPIPE back to its default. Zig's start code leaves the default
/// already, so a closed stdout ends the process quietly; kept for the
/// hosts that call it.
pub fn restoreSigpipe() void {
    const dfl: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.DFL }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(.PIPE, &dfl, null);
}

test "a cursor answer is read off the end" {
    try std.testing.expectEqual([2]usize{ 12, 40 }, parseCursor("\x1b[12;40R").?);
    try std.testing.expectEqual([2]usize{ 3, 1 }, parseCursor("junk\x1b[1;1R\x1b[3;1R").?);
    try std.testing.expect(parseCursor("\x1b[12;40") == null);
    var buf: [48]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[r\x1b[17;1H\x1b[J\x1b[?25h", regionReset(&buf, 17));
}
