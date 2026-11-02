//! What differs between operating systems, behind one interface. Only the
//! Linux backend exists; Windows and a portable fallback do not.

const std = @import("std");
const linux = std.os.linux;
const Env = @import("env.zig").Env;

pub const fs = @import("sys/fs.zig");
pub const tty = @import("sys/tty.zig");
pub const fault = @import("sys/fault.zig");
pub const process = @import("sys/process.zig");
pub const vm = @import("sys/vm.zig");
pub const net = @import("sys/net.zig");

/// `name` as a program to spawn: the caller's `PATH` decides, and the
/// directories the package bakes into `IETS_FALLBACK_PATH` serve a caller
/// with none, such as a systemd service. `out` holds the result when it is
/// a found fallback; otherwise `name` itself is returned.
pub fn program(env: Env, name: []const u8, fallback_path: ?[]const u8, out: []u8) []const u8 {
    if (env.get("PATH")) |p| if (findIn(p, name, out) != null) return name;
    if (fallback_path) |d| if (findIn(d, name, out)) |found| return found;
    return name;
}

fn findIn(dirs: []const u8, name: []const u8, out: []u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, dirs, ':');
    while (it.next()) |d| {
        const p = std.fmt.bufPrint(out, "{s}/{s}", .{ if (d.len == 0) "." else d, name }) catch continue;
        if (fs.runnableFile(p)) return p;
    }
    return null;
}

/// Fills `buf` from the system's random source. A failure leaves zeros: the
/// bytes are a cache key or a name suffix, and nothing here can act on it.
pub fn random(buf: []u8) void {
    @memset(buf, 0);
    var at: usize = 0;
    while (at < buf.len) {
        const rc = linux.getrandom(buf[at..].ptr, buf.len - at, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => at += rc,
            .INTR => {},
            else => return,
        }
    }
}

/// Wall-clock milliseconds since the Unix epoch.
pub fn unixMillis() u64 {
    var ts: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.REALTIME, &ts)) != .SUCCESS) return 0;
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

/// A monotonic clock in nanoseconds, for durations.
pub fn monotonicNs() u64 {
    var ts: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &ts)) != .SUCCESS) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub fn sleepNs(ns: u64) void {
    var req: linux.timespec = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
    while (true) {
        var rem: linux.timespec = undefined;
        switch (linux.errno(linux.nanosleep(&req, &rem))) {
            .INTR => req = rem,
            else => return,
        }
    }
}

pub fn pid() u32 {
    return @intCast(linux.getpid());
}

/// The temporary directory: `$TMPDIR`, else `/tmp`.
pub fn tempDir(env: Env) []const u8 {
    return env.nonEmpty("TMPDIR") orelse "/tmp";
}

test "random fills" {
    var a: [16]u8 = undefined;
    var b: [16]u8 = undefined;
    random(&a);
    random(&b);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test {
    std.testing.refAllDecls(fs);
    std.testing.refAllDecls(tty);
    std.testing.refAllDecls(fault);
    std.testing.refAllDecls(process);
    std.testing.refAllDecls(vm);
    std.testing.refAllDecls(net);
}
