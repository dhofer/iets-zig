//! TLS for the gRPC client: std's TLS 1.3/1.2 client extended with ALPN and
//! client certificates (`Client.zig`), private keys (`key.zig`) and PEM
//! loading plus CA bundles (`pem.zig`).
//!
//! Tests: `zig test src/remote/grpc/tls/tls.zig`. The handshake tests run
//! against a real `openssl s_server` and are skipped unless
//! `IETS_TEST_OPENSSL` names the openssl binary:
//!
//!     IETS_TEST_OPENSSL=$(nix shell nixpkgs#openssl -c which openssl) \
//!         zig test src/remote/grpc/tls/tls.zig

const std = @import("std");

pub const Client = @import("Client.zig");
pub const key = @import("key.zig");
pub const pem = @import("pem.zig");
pub const PrivateKey = key.PrivateKey;
pub const Identity = Client.Identity;

test {
    std.testing.refAllDecls(Client);
    std.testing.refAllDecls(key);
    std.testing.refAllDecls(pem);
    _ = &Client.init;
}

const testing = std.testing;
const Io = std.Io;

/// Runs `argv` in `dir`, failing the test on a non-zero exit.
fn runTool(io: Io, dir: Io.Dir, argv: []const []const u8) !void {
    const result = try std.process.run(testing.allocator, io, .{ .argv = argv, .cwd = .{ .dir = dir } });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    std.debug.print("{s} failed:\n{s}\n", .{ argv[0], result.stderr });
    return error.ToolFailed;
}

/// `openssl req` options generating a key of `kind`.
fn newKeyArgs(kind: []const u8) []const []const u8 {
    if (std.mem.eql(u8, kind, "p256")) return &.{ "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256" };
    if (std.mem.eql(u8, kind, "p384")) return &.{ "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-384" };
    if (std.mem.eql(u8, kind, "ed25519")) return &.{ "-newkey", "ed25519" };
    if (std.mem.eql(u8, kind, "rsa4096")) return &.{ "-newkey", "rsa:4096" };
    return &.{ "-newkey", "rsa:2048" };
}

/// A CA, and certificates it signed for `name` with a key of `kind`
/// (`name.pem`, `name.key`). The client keys are converted to the
/// traditional SEC1/PKCS#1 encodings for some kinds to cover both parsers.
/// A test CA, servers for localhost and clients of every key type, made by
/// `openssl` in `dir` (the gRPC TLS test uses it too).
pub fn makePki(io: Io, dir: Io.Dir, openssl: []const u8) !void {
    try runTool(io, dir, &.{ openssl, "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes", "-keyout", "ca.key", "-out", "ca.pem", "-subj", "/CN=iets test CA", "-days", "2" });
    const leaves = [_][2][]const u8{
        .{ "server-ec", "p256" },         .{ "server-rsa", "rsa" },         .{ "client-p256", "p256" },
        .{ "client-p384", "p384" },       .{ "client-ed25519", "ed25519" }, .{ "client-rsa", "rsa" },
        .{ "client-rsa4096", "rsa4096" },
    };
    for (leaves) |leaf| {
        var buf: [4][64]u8 = undefined;
        const keyf = try std.fmt.bufPrint(&buf[0], "{s}.key", .{leaf[0]});
        const csr = try std.fmt.bufPrint(&buf[1], "{s}.csr", .{leaf[0]});
        const crt = try std.fmt.bufPrint(&buf[2], "{s}.pem", .{leaf[0]});
        const server = std.mem.startsWith(u8, leaf[0], "server");
        const subj = if (server) "/CN=localhost" else "/CN=iets client";
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(testing.allocator);
        try argv.appendSlice(testing.allocator, &.{ openssl, "req" });
        try argv.appendSlice(testing.allocator, newKeyArgs(leaf[1]));
        try argv.appendSlice(testing.allocator, &.{ "-nodes", "-keyout", keyf, "-out", csr, "-subj", subj });
        if (server) try argv.appendSlice(testing.allocator, &.{ "-addext", "subjectAltName=DNS:localhost" });
        try runTool(io, dir, argv.items);
        try runTool(io, dir, &.{ openssl, "x509", "-req", "-in", csr, "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial", "-out", crt, "-days", "2", "-copy_extensions", "copy" });
    }
    // Traditional encodings: "EC PRIVATE KEY" and "RSA PRIVATE KEY".
    try runTool(io, dir, &.{ openssl, "ec", "-in", "client-p384.key", "-out", "client-p384.key" });
    try runTool(io, dir, &.{ openssl, "rsa", "-traditional", "-in", "client-rsa.key", "-out", "client-rsa.key" });
}

const Server = struct {
    child: std.process.Child,
    port: u16,

    fn stop(s: *Server, io: Io) void {
        s.child.kill(io);
    }
};

var next_port: u16 = 0;

/// Starts `openssl s_server` as an echo server (`-rev`) that requires a
/// client certificate from our CA and offers ALPN h2.
fn startServer(io: Io, dir: Io.Dir, openssl: []const u8, version: []const u8, server: []const u8) !Server {
    if (next_port == 0) {
        var r: [2]u8 = undefined;
        io.random(&r);
        next_port = 20000 + std.mem.readInt(u16, &r, .little) % 20000;
    }
    var attempts: usize = 0;
    while (true) : (attempts += 1) {
        next_port += 1;
        var port_buf: [8]u8 = undefined;
        const port = try std.fmt.bufPrint(&port_buf, "{d}", .{next_port});
        var cert_buf: [64]u8 = undefined;
        var key_buf: [64]u8 = undefined;
        var child = try std.process.spawn(io, .{
            .argv = &.{
                openssl,                                              "s_server", "-accept", port,    "-naccept",                                            "1",
                version,                                              "-alpn",    "h2",      "-rev",  "-Verify",                                             "1",
                "-verify_return_error",                               "-CAfile",  "ca.pem",  "-cert", try std.fmt.bufPrint(&cert_buf, "{s}.pem", .{server}), "-key",
                try std.fmt.bufPrint(&key_buf, "{s}.key", .{server}),
            },
            .cwd = .{ .dir = dir },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        // s_server prints "ACCEPT" once it listens; "unable to bind" otherwise.
        var buf: [4096]u8 = undefined;
        var reader = child.stdout.?.readerStreaming(io, &buf);
        while (reader.interface.takeDelimiterInclusive('\n')) |line| {
            if (std.mem.startsWith(u8, line, "ACCEPT")) return .{ .child = child, .port = next_port };
        } else |_| {}
        child.kill(io);
        if (attempts == 5) return error.ServerDidNotStart;
    }
}

const Outcome = struct {
    version: std.crypto.tls.ProtocolVersion,
    alpn_buf: [255]u8 = undefined,
    alpn_len: usize = 0,
    echo_buf: [64]u8 = undefined,
    echo_len: usize = 0,

    fn alpn(o: *const Outcome) []const u8 {
        return o.alpn_buf[0..o.alpn_len];
    }
    fn echo(o: *const Outcome) []const u8 {
        return o.echo_buf[0..o.echo_len];
    }
};

/// Handshakes with the server on `port`, sends a line and reads the echo.
/// `alert` receives the server's alert when `error.TlsAlert` is returned.
/// A null `bundle` skips server verification (and sends no SNI).
fn exchange(io: Io, port: u16, bundle: ?*std.crypto.Certificate.Bundle, identity: ?Identity, alert: *std.crypto.tls.Alert) !Outcome {
    const addr = try Io.net.IpAddress.parse("127.0.0.1", port);
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var socket_read: [Client.min_buffer_len]u8 = undefined;
    var socket_write: [Client.min_buffer_len]u8 = undefined;
    var tls_read: [Client.min_buffer_len]u8 = undefined;
    var tls_write: [Client.min_buffer_len]u8 = undefined;
    var sr = stream.reader(io, &socket_read);
    var sw = stream.writer(io, &socket_write);
    var entropy: [Client.Options.entropy_len]u8 = undefined;
    io.random(&entropy);
    var lock: Io.RwLock = .init;
    var client = Client.init(&sr.interface, &sw.interface, .{
        .host = if (bundle == null) .no_verification else .{ .explicit = "localhost" },
        .ca = if (bundle) |b| .{ .bundle = .{ .gpa = testing.allocator, .io = io, .lock = &lock, .bundle = b } } else .no_verification,
        .read_buffer = &tls_read,
        .write_buffer = &tls_write,
        .entropy = &entropy,
        .realtime_now = Io.Timestamp.now(io, .real),
        .alpn = &.{ "h2", "http/1.1" },
        .identity = identity,
        .alert = alert,
    }) catch |err| switch (err) {
        error.ReadFailed => return sr.err.?,
        error.WriteFailed => return sw.err.?,
        else => |e| return e,
    };
    var out: Outcome = .{ .version = client.tls_version };
    if (client.alpnProtocol()) |p| {
        @memcpy(out.alpn_buf[0..p.len], p);
        out.alpn_len = p.len;
    }
    try client.writer.writeAll("hello iets\n");
    try client.writer.flush();
    try sw.interface.flush();
    const line = client.reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
        error.ReadFailed => {
            if (client.alert) |a| alert.* = a;
            return client.read_err orelse sr.err.?;
        },
        else => |e| return e,
    };
    @memcpy(out.echo_buf[0..line.len], line);
    out.echo_len = line.len;
    try client.end();
    try sw.interface.flush();
    return out;
}

fn loadIdentity(io: Io, dir: Io.Dir, name: []const u8) !pem.OwnedIdentity {
    var buf: [2][64]u8 = undefined;
    const cert_pem = try dir.readFileAlloc(io, try std.fmt.bufPrint(&buf[0], "{s}.pem", .{name}), testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(cert_pem);
    const key_pem = try dir.readFileAlloc(io, try std.fmt.bufPrint(&buf[1], "{s}.key", .{name}), testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(key_pem);
    return pem.parseIdentity(testing.allocator, cert_pem, key_pem);
}

test "handshake with openssl s_server: ALPN h2 and client certificates, TLS 1.3 and 1.2" {
    const openssl = testing.environ.getPosix("IETS_TEST_OPENSSL") orelse return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makePki(io, tmp.dir, openssl);

    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(testing.allocator);
    {
        const ca = try tmp.dir.readFileAlloc(io, "ca.pem", testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(ca);
        try pem.addCertsFromPem(&bundle, testing.allocator, Io.Timestamp.now(io, .real), ca);
    }

    const Case = struct { version: []const u8, server: []const u8, client: []const u8 };
    const cases = [_]Case{
        .{ .version = "-tls1_3", .server = "server-ec", .client = "client-p256" },
        .{ .version = "-tls1_3", .server = "server-ec", .client = "client-p384" },
        .{ .version = "-tls1_3", .server = "server-ec", .client = "client-ed25519" },
        .{ .version = "-tls1_3", .server = "server-rsa", .client = "client-rsa" },
        .{ .version = "-tls1_2", .server = "server-ec", .client = "client-p256" },
        .{ .version = "-tls1_2", .server = "server-ec", .client = "client-p384" },
        .{ .version = "-tls1_2", .server = "server-rsa", .client = "client-rsa" },
        .{ .version = "-tls1_2", .server = "server-rsa", .client = "client-p256" },
    };
    for (cases) |case| {
        errdefer std.debug.print("case {s} {s} {s}\n", .{ case.version, case.server, case.client });
        var id = try loadIdentity(io, tmp.dir, case.client);
        defer id.deinit(testing.allocator);
        var server = try startServer(io, tmp.dir, openssl, case.version, case.server);
        defer server.stop(io);
        var alert: std.crypto.tls.Alert = undefined;
        const out = try exchange(io, server.port, &bundle, id.identity(), &alert);
        try testing.expectEqual(@as(std.crypto.tls.ProtocolVersion, if (std.mem.eql(u8, case.version, "-tls1_3")) .tls_1_3 else .tls_1_2), out.version);
        try testing.expectEqualStrings("h2", out.alpn());
        try testing.expectEqualStrings("stei olleh\n", out.echo());
    }

    // Without SNI the ClientHello ends with the ALPN extension.
    for ([_][]const u8{ "-tls1_3", "-tls1_2" }) |version| {
        var id = try loadIdentity(io, tmp.dir, "client-p256");
        defer id.deinit(testing.allocator);
        var server = try startServer(io, tmp.dir, openssl, version, "server-ec");
        defer server.stop(io);
        var alert: std.crypto.tls.Alert = undefined;
        const out = try exchange(io, server.port, null, id.identity(), &alert);
        try testing.expectEqualStrings("h2", out.alpn());
    }

    // A chain longer than one record: the leaf plus the CA, repeated, which
    // the server ignores beyond building the path.
    {
        var id = try loadIdentity(io, tmp.dir, "client-rsa4096");
        defer id.deinit(testing.allocator);
        const ca_pem = try tmp.dir.readFileAlloc(io, "ca.pem", testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(ca_pem);
        const ca_chain = try pem.parseCertificateChain(testing.allocator, ca_pem);
        defer ca_chain.deinit(testing.allocator);
        var chain: [32][]const u8 = undefined;
        chain[0] = id.chain.certs[0];
        for (chain[1..]) |*c| c.* = ca_chain.certs[0];
        var total: usize = 0;
        for (chain) |c| total += c.len;
        try testing.expect(total > 2 * 4096);
        for ([_][]const u8{ "-tls1_3", "-tls1_2" }) |version| {
            var server = try startServer(io, tmp.dir, openssl, version, "server-rsa");
            defer server.stop(io);
            var alert: std.crypto.tls.Alert = undefined;
            const out = try exchange(io, server.port, &bundle, .{ .chain = &chain, .key = &id.key }, &alert);
            try testing.expectEqualStrings("stei olleh\n", out.echo());
        }
    }

    // Without an identity we answer with an empty Certificate, and with a
    // certificate from another CA the server cannot verify it: refusals
    // that show the server checks what we send.
    try runTool(io, tmp.dir, &.{ openssl, "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes", "-keyout", "stranger.key", "-out", "stranger.pem", "-subj", "/CN=stranger", "-days", "2" });
    var stranger = try loadIdentity(io, tmp.dir, "stranger");
    defer stranger.deinit(testing.allocator);
    const Refusal = struct { version: []const u8, identity: ?Identity, alert: std.crypto.tls.Alert.Description };
    const refusals = [_]Refusal{
        .{ .version = "-tls1_3", .identity = null, .alert = .certificate_required },
        .{ .version = "-tls1_2", .identity = null, .alert = .handshake_failure },
        .{ .version = "-tls1_3", .identity = stranger.identity(), .alert = .unknown_ca },
        .{ .version = "-tls1_2", .identity = stranger.identity(), .alert = .unknown_ca },
    };
    for (refusals) |r| {
        errdefer std.debug.print("refusal case {s}\n", .{r.version});
        var server = try startServer(io, tmp.dir, openssl, r.version, "server-ec");
        defer server.stop(io);
        var alert: std.crypto.tls.Alert = undefined;
        try testing.expectError(error.TlsAlert, exchange(io, server.port, &bundle, r.identity, &alert));
        try testing.expectEqual(r.alert, alert.description);
    }
}
