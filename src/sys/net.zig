//! TCP connects bounded by a deadline. std's `connect` has no timeout yet, so the wait is a `poll` on a
//! nonblocking connect. Linux only.

const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const linux = std.os.linux;

/// TCP to the first address of `host` that answers, tried in the order the
/// resolver gives them. `deadline` is on
/// the awake clock, in nanoseconds; past it the connect fails with
/// `error.Timeout`, and null waits as long as the OS does. The name lookup
/// itself is not bounded. The socket is left blocking.
pub fn connect(io: Io, host: Io.net.HostName, port: u16, deadline: ?i96) !Io.net.Stream {
    var results: [32]Io.net.HostName.LookupResult = undefined;
    var q: Io.Queue(Io.net.HostName.LookupResult) = .init(&results);
    try host.lookup(io, &q, .{ .port = port });
    var last: anyerror = error.UnknownHostName;
    while (q.getOne(io)) |r| switch (r) {
        .address => |addr| return connectAddr(io, addr, deadline) catch |e| {
            if (e == error.Timeout) return e;
            last = e;
            continue;
        },
        .canonical_name => {},
    } else |_| {}
    return last;
}

/// `connect` to one address.
pub fn connectAddr(io: Io, addr: Io.net.IpAddress, deadline: ?i96) !Io.net.Stream {
    var sa: linux.sockaddr.in6 = undefined;
    var sa4: linux.sockaddr.in = undefined;
    const family: u32, const sp: *const linux.sockaddr, const len: linux.socklen_t = switch (addr) {
        .ip4 => |a4| blk: {
            sa4 = .{ .port = std.mem.nativeToBig(u16, a4.port), .addr = @bitCast(a4.bytes) };
            break :blk .{ linux.AF.INET, @ptrCast(&sa4), @sizeOf(linux.sockaddr.in) };
        },
        .ip6 => |a6| blk: {
            sa = .{ .port = std.mem.nativeToBig(u16, a6.port), .flowinfo = a6.flow, .addr = a6.bytes, .scope_id = a6.interface.index };
            break :blk .{ linux.AF.INET6, @ptrCast(&sa), @sizeOf(linux.sockaddr.in6) };
        },
    };
    const fd_rc = linux.socket(family, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, linux.IPPROTO.TCP);
    if (linux.errno(fd_rc) != .SUCCESS) return error.SystemResources;
    const fd: posix.fd_t = @intCast(fd_rc);
    errdefer _ = linux.close(fd);
    while (true) switch (linux.errno(linux.connect(fd, sp, len))) {
        .SUCCESS => break,
        .INTR => continue,
        .INPROGRESS => {
            const ms: i32 = if (deadline) |dl| blk: {
                const left = dl - Io.Clock.awake.now(io).nanoseconds;
                if (left <= 0) return error.Timeout;
                break :blk @intCast(@min(@divFloor(left + std.time.ns_per_ms - 1, std.time.ns_per_ms), std.math.maxInt(i32)));
            } else -1;
            var pfd = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
            if (try posix.poll(&pfd, ms) == 0) return error.Timeout;
            var err: i32 = 0;
            var elen: linux.socklen_t = @sizeOf(i32);
            _ = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(&err), &elen);
            if (err != 0) return errnoError(@fromBackingInt(@intCast(err)));
            break;
        },
        else => |e| return errnoError(e),
    };
    const fl = linux.fcntl(fd, linux.F.GETFL, 0);
    _ = linux.fcntl(fd, linux.F.SETFL, fl & ~@as(usize, @as(u32, @bitCast(linux.O{ .NONBLOCK = true }))));
    return .{ .socket = .{ .handle = fd, .address = addr } };
}

fn errnoError(e: linux.E) anyerror {
    return switch (e) {
        .CONNREFUSED => error.ConnectionRefused,
        .NETUNREACH => error.NetworkUnreachable,
        .HOSTUNREACH => error.HostUnreachable,
        .TIMEDOUT => error.ConnectionTimedOut,
        .CONNRESET => error.ConnectionResetByPeer,
        .ACCES, .PERM => error.AccessDenied,
        else => error.Unexpected,
    };
}

const testing = std.testing;

test "a refused port says so" {
    const io = testing.io;
    var server = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    const port = server.socket.address.getPort();
    server.deinit(io);
    const addr = try Io.net.IpAddress.parse("127.0.0.1", port);
    try testing.expectError(error.ConnectionRefused, connectAddr(io, addr, Io.Clock.awake.now(io).nanoseconds + std.time.ns_per_s));
}

test "a listening port connects" {
    const io = testing.io;
    var server = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer server.deinit(io);
    const s = try connectAddr(io, server.socket.address, null);
    s.close(io);
}
