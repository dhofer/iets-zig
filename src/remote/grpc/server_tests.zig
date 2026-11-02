//! The native gRPC client (HTTP/2, HPACK, flow control, the call shapes and
//! the retry loops) against a real gRPC server: grpcio's, running
//! testdata/server.py, a stand-in for nix-grpc-store. Skipped unless
//! `IETS_TEST_GRPC_PYTHON` names a python3 (3.14, for compression.zstd)
//! with grpcio:
//!
//!     IETS_TEST_GRPC_PYTHON=$(nix build --no-link --print-out-paths --impure \
//!       --expr 'with import <nixpkgs> {}; python3.withPackages (p: [p.grpcio])')/bin/python3 \
//!       zig build test
//!
//! These drive the gRPC client layer directly against nix-grpc-daemon,
//! without `iets build` in between.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Diag = @import("../../diag.zig").Diag;
const remote = @import("../../remote.zig");
const proto = @import("proto.zig");
const config = @import("config.zig");
const client_mod = @import("client.zig");
const Client = client_mod.Client;
const sched_mod = @import("sched.zig");
const build = @import("build.zig");

const script = @embedFile("testdata/server.py");

const Server = struct {
    child: std.process.Child,
    port: u16,
    tmp: testing.TmpDir,

    fn start() !?Server {
        return startWith(&.{});
    }

    /// `args` are the script's: a certificate, its key and a client CA, as
    /// files in the server's directory, made by `pki` before the start.
    fn startWith(args: []const []const u8) !?Server {
        const python = testing.environ.getPosix("IETS_TEST_GRPC_PYTHON") orelse return null;
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        return try startIn(python, tmp, args);
    }

    fn startIn(python: []const u8, tmp: testing.TmpDir, args: []const []const u8) !Server {
        const io = testing.io;
        try tmp.dir.writeFile(io, .{ .sub_path = "server.py", .data = script });
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPathFile(io, "server.py", &buf);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(testing.allocator);
        try argv.appendSlice(testing.allocator, &.{ python, buf[0..n] });
        try argv.appendSlice(testing.allocator, args);
        var child = try std.process.spawn(io, .{
            .argv = argv.items,
            .cwd = .{ .dir = tmp.dir },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        errdefer child.kill(io);
        var rbuf: [64]u8 = undefined;
        var r = child.stdout.?.readerStreaming(io, &rbuf);
        const line = try r.interface.takeDelimiterExclusive('\n');
        const port = try std.fmt.parseInt(u16, std.mem.trim(u8, line, " \r"), 10);
        return .{ .child = child, .port = port, .tmp = tmp };
    }

    fn stop(s: *Server) void {
        const io = testing.io;
        if (s.child.stdin) |f| f.close(io);
        s.child.stdin = null;
        s.child.kill(io);
        s.tmp.cleanup();
    }

    fn url(s: *const Server, buf: []u8, query: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "grpc://127.0.0.1:{d}?insecure=1&connect-timeout=10{s}", .{ s.port, query }) catch unreachable;
    }
};

fn open(arena: std.mem.Allocator, s: *const Server, query: []const u8, d: *Diag) !*Client {
    var ubuf: [256]u8 = undefined;
    const cfg = (try config.Config.parse(arena, s.url(&ubuf, query), "x86_64-linux", d)).?;
    return Client.open(testing.allocator, testing.io, cfg, .none, d) catch |e| {
        std.debug.print("{s}\n", .{d.message()});
        return e;
    };
}

test "unary calls, statuses and the UNAVAILABLE retry against grpcio" {
    var srv = try Server.start() orelse return error.SkipZigTest;
    defer srv.stop();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const c = try open(a, &srv, "", &d);
    defer c.close();
    try testing.expectEqual(true, c.info.trusted.?);

    const reply = try c.call(proto.QueryValidPathsReply, a, "QueryValidPaths", proto.QueryValidPathsRequest{ .paths = &.{ "aaa-x", "bbb-missing", "ccc-y" } }, &d);
    try testing.expectEqual(2, reply.paths.len);
    try testing.expectEqualStrings("ccc-y", reply.paths[1]);

    // two UNAVAILABLE "upstream" answers are retried, the third succeeds
    const flaky = try c.call(proto.QueryMissingReply, a, "QueryMissing", proto.QueryMissingRequest{ .targets = &.{"flaky"} }, &d);
    try testing.expectEqualStrings("after 3 tries", flaky.will_build[0]);

    // anything else fails at once, with the status and its decoded message
    try testing.expectError(error.Protocol, c.call(proto.QueryMissingReply, a, "QueryMissing", proto.QueryMissingRequest{ .targets = &.{"denied"} }, &d));
    var want_buf: [256]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&want_buf, "gRPC QueryMissing on '127.0.0.1:{d}' failed (PermissionDenied): no access to 100% of it", .{srv.port}), d.message());

    // many calls at once share the connection
    const T = struct {
        fn run(cl: *Client, ok: *std.atomic.Value(u32)) void {
            var ar: std.heap.ArenaAllocator = .init(testing.allocator);
            defer ar.deinit();
            var dd: Diag = .init(testing.allocator);
            defer dd.deinit();
            for (0..20) |_| {
                const r = cl.call(proto.QueryValidPathsReply, ar.allocator(), "QueryValidPaths", proto.QueryValidPathsRequest{ .paths = &.{"p"} }, &dd) catch return;
                if (r.paths.len == 1) _ = ok.fetchAdd(1, .monotonic);
            }
        }
    };
    var ok: std.atomic.Value(u32) = .init(0);
    var threads: [8]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, T.run, .{ c, &ok });
    for (threads) |t| t.join();
    try testing.expectEqual(160, ok.load(.monotonic));
}

test "a refused connection names the server and the hint" {
    var srv = try Server.start() orelse return error.SkipZigTest;
    const port = srv.port;
    srv.stop();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var ubuf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&ubuf, "grpc://127.0.0.1:{d}?insecure=1", .{port});
    const cfg = (try config.Config.parse(arena_state.allocator(), url, "x86_64-linux", &d)).?;
    try testing.expectError(error.Protocol, Client.open(testing.allocator, testing.io, cfg, .none, &d));
    var want: [256]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&want, "cannot connect to 'grpc://127.0.0.1:{d}': transport error: tcp connect error: Connection refused" ++
        "\nhint: could not reach the server (TCP/DNS), not a certificate problem.", .{port}), d.message());
}

test "the scheduler stream answers each want" {
    var srv = try Server.start() orelse return error.SkipZigTest;
    defer srv.stop();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const c = try open(a, &srv, "", &d);
    defer c.close();
    const s = try sched_mod.Sched.open(testing.allocator, c);
    defer s.close();
    const assigned = try s.place(a, .{ .drv_path = "aaa-x.drv", .system = "x86_64-linux" }, &d);
    try testing.expectEqualStrings("w1:1", assigned.assigned.worker);
    try testing.expectEqual(7, assigned.assigned.assign_id);
    try testing.expect(try s.place(a, .{ .drv_path = "bbb-cached.drv" }, &d) == .cached);
}

test "server streams: FetchNars frames through one zstd stream" {
    var srv = try Server.start() orelse return error.SkipZigTest;
    defer srv.stop();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const c = try open(a, &srv, "", &d);
    defer c.close();
    const names = [_][]const u8{ "0123456789abcdfghijklmnpqrsvwxyz-one", "0123456789abcdfghijklmnpqrsvwxyz-two" };
    var got: [2]std.ArrayList(u8) = .{ .empty, .empty };
    defer for (&got) |*g| g.deinit(testing.allocator);
    var eofs: [2]bool = .{ false, false };
    const s = try build.NarStream.open(c, &names, &d);
    defer s.close();
    while (try s.next()) |i| {
        try s.reader.appendRemainingUnlimited(testing.allocator, &got[i]);
        eofs[i] = s.eof;
    }
    try s.finish();
    for (names, got, eofs) |n, g, e| {
        try testing.expect(e);
        try testing.expectEqual(n.len * 20000, g.items.len);
        try testing.expectEqualStrings(n, g.items[g.items.len - n.len ..]);
    }
}

const plan = @import("../plan.zig");
const wire = @import("../worker/wire.zig");
const hash_mod = @import("../../store/hash.zig");
const path_mod = @import("../../store/path.zig");
const drv_mod = @import("../../store/drv.zig");
const event = @import("../event.zig");

test "AddMultipleToStore sends one zstd stream of the worker framing" {
    var srv = try Server.start() orelse return error.SkipZigTest;
    defer srv.stop();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const c = try open(a, &srv, "", &d);
    defer c.close();
    // a text and a .drv, with a NAR big enough for several chunks
    const big = try a.alloc(u8, 3 << 20);
    for (big, 0..) |*b, i| b.* = @truncate(i *% 2654435761 >> 13);
    const text_path = try path_mod.makeTextPath("big", hash_mod.hashBytes(.sha256, big), .{}, &d);
    const nh = try plan.hashSource(testing.allocator, testing.io, .mem(big), &d);
    var objs = [_]plan.Object{
        .{ .source = .{ .path = text_path, .at = .mem(big), .kind = .{ .text = &.{} }, .nar_hash = nh.hash, .nar_size = nh.size } },
        .drvObject(try path_mod.StorePath.parse("/nix/store/7q6r5bxprr5bzxqyhjmzjvcg9c0sfbyk-a.drv", &d), "Derive([],[],[],\"x\",\"y\",[],[])", &.{}),
    };
    const ptrs = [_]*plan.Object{ &objs[0], &objs[1] };
    var t: build.Timings = .{};
    const sent = try build.addMultiple(c, &ptrs, &t, &d);
    try testing.expect(sent > 0 and sent < 3 << 20);

    var want: std.Io.Writer.Allocating = .init(testing.allocator);
    defer want.deinit();
    try wire.writeU64(&want.writer, 2);
    for (&ptrs) |o| try wire.writeObject(testing.allocator, testing.io, &want.writer, o, &d);
    var hex: [64]u8 = undefined;
    const h = hash_mod.hashBytes(.sha256, want.written());
    const reply = try c.call(proto.QueryMissingReply, a, "QueryMissing", proto.QueryMissingRequest{ .targets = &.{"last-upload"} }, &d);
    try testing.expectEqualStrings(h.print(&hex, .base16, false), reply.will_build[0]);
    try testing.expectEqual(want.written().len, reply.download_size);
}

const Events = struct {
    lock: std.Io.Mutex = .init,
    logs: usize = 0,
    phases: usize = 0,
    pub fn onEvent(e: *Events, ev: event.Event) void {
        e.lock.lockUncancelable(testing.io);
        defer e.lock.unlock(testing.io);
        switch (ev) {
            .log => e.logs += 1,
            .phase => e.phases += 1,
            else => {},
        }
    }
};

test "BuildDerivation through the scheduler, with the NOT_FOUND upload" {
    var srv = try Server.start() orelse return error.SkipZigTest;
    defer srv.stop();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const c = try open(a, &srv, "", &d);
    defer c.close();
    const s = try sched_mod.Sched.open(testing.allocator, c);
    defer s.close();
    const aterm = "Derive([(\"out\",\"/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-x\",\"\",\"\")],[],[],\"x86_64-linux\",\"/bin/sh\",[],[(\"out\",\"/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-x\")])";
    const drv = try drv_mod.Derivation.parse(a, aterm, "missing-needs-upload", &d);
    const drv_path = try path_mod.StorePath.parse("/nix/store/7q6r5bxprr5bzxqyhjmzjvcg9c0sfbyk-missing-needs-upload.drv", &d);
    const job = try build.Job.init(a, drv_path, &drv, &.{});
    var objects: build.Objects = .init(testing.allocator);
    defer objects.deinit();
    var obj: plan.Object = .drvObject(drv_path, aterm, &.{});
    try objects.extend(&.{&obj});
    var evs: Events = .{};
    const got = try build.build(c, a, s, &job, &objects, .of(Events, &evs), .{ .log = .none, .id = 0 }, &d);
    try testing.expect(got.res.success());
    // the bounce, the upload's query and add, the retry
    try testing.expectEqual(4, got.calls);
    try testing.expectEqual(1, evs.logs);
    try testing.expectEqual(1, evs.phases);

    const failing = try path_mod.StorePath.parse("/nix/store/7q6r5bxprr5bzxqyhjmzjvcg9c0sfbyk-fails.drv", &d);
    const job2 = try build.Job.init(a, failing, &drv, &.{});
    const got2 = try build.build(c, a, s, &job2, &objects, .ignore, .{ .log = .none, .id = 0 }, &d);
    try testing.expect(!got2.res.success());
    try testing.expectEqualStrings("builder failed", got2.res.error_msg);
}

const backend_mod = @import("backend.zig");
const build_backend = @import("../../build/backend.zig");

const Batch = struct {
    drvs: []const build_backend.Drv,
    fn get(ctx: ?*anyopaque, _: bool, _: std.mem.Allocator, _: *Diag) anyerror![]const build_backend.Drv {
        const b: *@This() = @ptrCast(@alignCast(ctx.?));
        return b.drvs;
    }
};

fn testDrv(a: std.mem.Allocator, name: []const u8, out_hash: u8, inputs: []const path_mod.StorePath, d: *Diag) !build_backend.Drv {
    var aterm: std.ArrayList(u8) = .empty;
    const h: [32]u8 = @splat(out_hash);
    try aterm.print(a, "Derive([(\"out\",\"/nix/store/{s}-{s}\",\"\",\"\")],[", .{ &h, name });
    for (inputs, 0..) |in, i| {
        if (i > 0) try aterm.append(a, ',');
        try aterm.print(a, "(\"{f}\",[\"out\"])", .{&in});
    }
    try aterm.print(a, "],[],\"x86_64-linux\",\"/bin/sh\",[],[(\"out\",\"/nix/store/{s}-{s}\")])", .{ &h, name });
    const dh: [32]u8 = @splat(out_hash + 1);
    const p = try path_mod.StorePath.parse(try std.fmt.allocPrint(a, "/nix/store/{s}-{s}.drv", .{ &dh, name }), d);
    return .{ .path = p, .aterm = aterm.items };
}

test "the grpc backend fans a batch out and blocks what a failure needs" {
    var srv = try Server.start() orelse return error.SkipZigTest;
    defer srv.stop();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var ubuf: [256]u8 = undefined;
    const cfg = (try config.Config.parse(a, srv.url(&ubuf, "&max-builds=2"), "x86_64-linux", &d)).?;
    const g = try backend_mod.Grpc.open(testing.allocator, testing.io, cfg, null, .none, &d);
    defer g.close();
    // dep <- top, and fails <- after-fails, all with outputs the store lacks
    const dep = try testDrv(a, "missing-dep", 'a', &.{}, &d);
    const top = try testDrv(a, "missing-top", 'c', &.{dep.path}, &d);
    const fails = try testDrv(a, "missing-fails", 'f', &.{}, &d);
    const after = try testDrv(a, "missing-after", 'h', &.{fails.path}, &d);
    var batch: Batch = .{ .drvs = &.{ dep, top, fails, after } };
    var evs: Events = .{};
    const statuses = try g.submit(a, .{
        .jobs = &.{ .{ .drv = top.path }, .{ .drv = after.path } },
        .drvs_ctx = &batch,
        .drvs = Batch.get,
    }, .of(Events, &evs), &d);
    var pbuf: [512]u8 = undefined;
    try testing.expect(statuses.get(top.path.print(&pbuf)).?.ok);
    const blocked = statuses.get(after.path.print(&pbuf)).?;
    try testing.expect(!blocked.ok);
    try testing.expect(std.mem.startsWith(u8, blocked.reason, "status 10: dependency '"));
    try testing.expectEqual(100, blocked.exit);
    try testing.expectEqual(4, g.t.drvs);
    try testing.expectEqual(3, evs.logs);

    const outs = try g.outputs(a, top.path.print(&pbuf), &d);
    try testing.expectEqualStrings("out", outs[0].name);
}

// TLS with ALPN h2 and an mTLS client certificate, against grpcio's
// BoringSSL. Also needs `IETS_TEST_OPENSSL`, the openssl binary.
test "a TLS store with a client certificate" {
    const python = testing.environ.getPosix("IETS_TEST_GRPC_PYTHON") orelse return error.SkipZigTest;
    const openssl = testing.environ.getPosix("IETS_TEST_OPENSSL") orelse return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    try @import("tls/tls.zig").makePki(io, tmp.dir, openssl);
    var srv = try Server.startIn(python, tmp, &.{ "server-ec.pem", "server-ec.key", "ca.pem" });
    defer srv.stop();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPathFile(io, ".", &buf)];
    for ([_][]const u8{ "client-p256", "client-rsa" }) |client| {
        const url = try std.fmt.allocPrint(a, "grpc://localhost:{d}?ca-cert={s}/ca.pem&client-cert={s}/{s}.pem&client-key={s}/{s}.key", .{ srv.port, dir, dir, client, dir, client });
        const cfg = (try config.Config.parse(a, url, "x86_64-linux", &d)).?;
        const c = Client.open(testing.allocator, io, cfg, .none, &d) catch |e| {
            std.debug.print("{s}\n", .{d.message()});
            return e;
        };
        defer c.close();
        try testing.expectEqual(true, c.info.trusted.?);
        const reply = try c.call(proto.QueryValidPathsReply, a, "QueryValidPaths", proto.QueryValidPathsRequest{ .paths = &.{"aaa-x"} }, &d);
        try testing.expectEqual(1, reply.paths.len);
    }
    // without a client certificate the server refuses. Whether its alert
    // or the reset of the closed socket arrives first is a race (TLS 1.3
    // sends our preface along with the Finished), so only the connect
    // failure is certain.
    const url = try std.fmt.allocPrint(a, "grpc://localhost:{d}?ca-cert={s}/ca.pem", .{ srv.port, dir });
    const cfg = (try config.Config.parse(a, url, "x86_64-linux", &d)).?;
    if (Client.open(testing.allocator, io, cfg, .none, &d)) |c| {
        c.close();
        return error.TestExpectedError;
    } else |_| {}
    try testing.expect(std.mem.startsWith(u8, d.message(), "cannot connect to 'grpc://localhost:"));
}
