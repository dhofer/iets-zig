//! The worker-protocol client against the machine's nix-daemon, driven
//! directly rather than through `iets build`. Each test skips
//! when the daemon's socket is absent. The only write is one small text
//! path, the same each run, so the store grows by at most that path.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Diag = @import("../../diag.zig").Diag;
const worker = @import("../worker.zig");
const wire = @import("wire.zig");
const plan = @import("../plan.zig");
const path_mod = @import("../../store/path.zig");
const StorePath = path_mod.StorePath;
const hash_mod = @import("../../store/hash.zig");
const source = @import("../../store/source.zig");
const copy = @import("../copy.zig");

const socket = "/nix/var/nix/daemon-socket/socket";

fn daemon(d: *Diag) !?*worker.Connection {
    Io.Dir.cwd().access(testing.io, socket, .{}) catch return null;
    const t: worker.Transport = .{ .unix = socket };
    return try worker.Connection.open(testing.allocator, testing.io, &t, null, .none, .ignore, d);
}

/// A store path that is surely valid: the system's.
fn someValidPath(buf: []u8) ?[]const u8 {
    for ([_][]const u8{ "/run/current-system/sw", "/run/current-system" }) |link| {
        const n = Io.Dir.cwd().realPathFile(testing.io, link, buf) catch continue;
        const full = buf[0..n];
        const rest = path_mod.stripStoreDir(full) orelse continue;
        const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        return full[0 .. full.len - rest.len + end];
    }
    return null;
}

test "the handshake reports the daemon" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const c = (daemon(&d) catch |e| {
        std.debug.print("{s}\n", .{d.message()});
        return e;
    }) orelse return error.SkipZigTest;
    defer c.close();
    try testing.expect(c.minor >= worker.min_minor);
    try testing.expect(c.daemon_nix_version.len > 0);
    // handshake (2 at 1.38) + SetOptions
    try testing.expect(c.stats.round_trips >= 3);
    try testing.expectEqual(1, c.stats.ops);
    try testing.expect(c.bytesSent() > 0);
}

test "validity and path info of a store path" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const c = try daemon(&d) orelse return error.SkipZigTest;
    defer c.close();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const valid = someValidPath(&buf) orelse return error.SkipZigTest;
    const bogus = "/nix/store/00000000000000000000000000000000-iets-not-there";
    const got = try c.queryValid(a, &.{ try StorePath.parse(valid, &d), try StorePath.parse(bogus, &d) }, .ignore, &d);
    try testing.expectEqual(1, got.len);
    try testing.expectEqualStrings(valid[path_mod.store_dir.len + 1 ..], got[0].baseName());

    const info = (try c.queryPathInfo(a, valid, .ignore, &d)).?;
    try testing.expectEqual(64, info.nar_hash.len);
    try testing.expect(info.nar_size > 0);
    for (info.references) |r| _ = try StorePath.parse(r, &d);
    try testing.expectEqual(null, try c.queryPathInfo(a, bogus, .ignore, &d));
}

test "a NAR from the daemon hashes to its path info" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const c = try daemon(&d) orelse return error.SkipZigTest;
    defer c.close();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // the smallest path the system references keeps the read short
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const top = someValidPath(&buf) orelse return error.SkipZigTest;
    const top_info = (try c.queryPathInfo(a, top, .ignore, &d)).?;
    var best = top;
    var best_size = top_info.nar_size;
    for (top_info.references) |r| {
        const i = (try c.queryPathInfo(a, r, .ignore, &d)) orelse continue;
        if (i.nar_size < best_size) {
            best = r;
            best_size = i.nar_size;
        }
    }
    const info = (try c.queryPathInfo(a, best, .ignore, &d)).?;
    const r = try c.narReader(&try StorePath.parse(best, &d), .ignore, &d);
    var h: hash_mod.Hasher = .init(.sha256);
    var left = info.nar_size;
    while (left > 0) {
        const chunk = try r.take(@intCast(@min(left, r.buffer.len)));
        h.update(chunk);
        left -= chunk.len;
    }
    var hex: [64]u8 = undefined;
    try testing.expectEqualStrings(info.nar_hash, h.finish().print(&hex, .base16, false));
    // the connection is still in step after the NAR
    _ = try c.queryValid(a, &.{try StorePath.parse(best, &d)}, .ignore, &d);
}

test "a text path goes in with AddMultipleToStore" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const c = try daemon(&d) orelse return error.SkipZigTest;
    defer c.close();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const contents = "iets remote worker test\n";
    const flat = hash_mod.hashBytes(.sha256, contents);
    const p = try path_mod.makeTextPath("iets-remote-test", flat, .{}, &d);
    const at: source.SrcPath = .mem(contents);
    const nh = try plan.hashSource(testing.allocator, testing.io, at, &d);
    var objects = [_]plan.Object{.{ .source = .{ .path = p, .at = at, .kind = .{ .text = &.{} }, .nar_hash = nh.hash, .nar_size = nh.size } }};
    var up = try c.addMultipleToStore(false, &d);
    try wire.writeU64(up.writer(), objects.len);
    for (&objects) |*o| try wire.writeObject(testing.allocator, testing.io, up.writer(), o, &d);
    try up.finish(.ignore, &d);
    var pbuf: [512]u8 = undefined;
    const full = p.print(&pbuf);
    const got = try c.queryValid(a, &.{p}, .ignore, &d);
    try testing.expectEqual(1, got.len);
    const info = (try c.queryPathInfo(a, full, .ignore, &d)).?;
    var hex: [64]u8 = undefined;
    try testing.expectEqualStrings(nh.hash.print(&hex, .base16, false), info.nar_hash);
    try testing.expect(std.mem.startsWith(u8, info.ca, "text:sha256:"));

    // nothing is left to build or fetch for a valid path
    const m = try c.queryMissing(a, &.{full}, .ignore, &d);
    try testing.expectEqual(0, m.will_build.len + m.will_substitute.len + m.unknown.len);
    // a copy into the same store adds nothing
    const n = try copy.closure(testing.allocator, c, "daemon", c, &.{p}, .none, .ignore, &d);
    try testing.expectEqual(0, n);
}

test "a daemon error is a protocol error with the daemon's text" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const c = try daemon(&d) orelse return error.SkipZigTest;
    defer c.close();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.Protocol, c.queryDerivationOutputMap(arena_state.allocator(), "/nix/store/00000000000000000000000000000000-x.drv", .ignore, &d));
    try testing.expect(d.message().len > 0);
}

test "a missing socket is an io error naming it" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const t: worker.Transport = .{ .unix = "/nonexistent/iets/socket" };
    try testing.expectError(error.Io, worker.Connection.open(testing.allocator, testing.io, &t, null, .none, .ignore, &d));
    try testing.expectEqualStrings("cannot connect to '/nonexistent/iets/socket': No such file or directory", d.message());
}

// an `ssh` that ignores the host and runs the daemon on stdio here
test "the worker protocol over an ssh child" {
    const io = testing.io;
    Io.Dir.cwd().access(io, socket, .{}) catch return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "ssh", .data = "#!/bin/sh\nexec nix-daemon --stdio\n", .flags = .{ .permissions = .executable_file } });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const shim = buf[0..try tmp.dir.realPathFile(io, "ssh", &buf)];
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var t = worker.Transport.parse(a, "ssh-ng://shim", null).?;
    t.ssh.command = shim;
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const c = worker.Connection.open(testing.allocator, io, &t, null, .none, .ignore, &d) catch |e| {
        std.debug.print("{s}\n", .{d.message()});
        return e;
    };
    defer c.close();
    try testing.expect(c.minor >= worker.min_minor);
    // ssh-store.cc:setOptions sends nothing
    try testing.expectEqual(0, c.stats.ops);
    var vbuf: [std.fs.max_path_bytes]u8 = undefined;
    const valid = someValidPath(&vbuf) orelse return;
    const got = try c.queryValid(a, &.{try StorePath.parse(valid, &d)}, .ignore, &d);
    try testing.expectEqual(1, got.len);
}
