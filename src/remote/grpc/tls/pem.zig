//! PEM files (RFC 7468) for the TLS client: certificate chains, private
//! keys, and a CA bundle of the system roots plus extra PEM certificates.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const Certificate = std.crypto.Certificate;
const key = @import("key.zig");
const Client = @import("Client.zig");

pub const PrivateKey = key.PrivateKey;

const base64 = std.base64.standard.decoderWithIgnore(" \t\r\n");

pub const Error = error{
    /// A BEGIN line without its END line, or a malformed boundary.
    InvalidPem,
    /// The PEM text has no block of the wanted kind.
    NoPemBlock,
    /// "ENCRYPTED PRIVATE KEY" or a legacy "Proc-Type: 4,ENCRYPTED" key.
    EncryptedPrivateKey,
} || std.base64.Error || key.ParseError;

pub const Block = struct {
    /// The text between "-----BEGIN " and "-----", e.g. "CERTIFICATE".
    label: []const u8,
    /// The base64 body, still encoded.
    body: []const u8,
};

/// Iterates over the PEM blocks in `text`; text outside blocks is ignored,
/// as RFC 7468 §2 allows.
pub const Iterator = struct {
    text: []const u8,
    i: usize = 0,

    pub fn next(it: *Iterator) error{InvalidPem}!?Block {
        const begin = "-----BEGIN ";
        const start = mem.findPos(u8, it.text, it.i, begin) orelse return null;
        const label_start = start + begin.len;
        const label_end = mem.findPos(u8, it.text, label_start, "-----") orelse return error.InvalidPem;
        const label = it.text[label_start..label_end];
        if (mem.findAny(u8, label, "\r\n") != null) return error.InvalidPem;
        const body_start = label_end + 5;
        var end_buf: [80]u8 = undefined;
        const end_marker = std.fmt.bufPrint(&end_buf, "-----END {s}-----", .{label}) catch return error.InvalidPem;
        const body_end = mem.findPos(u8, it.text, body_start, end_marker) orelse return error.InvalidPem;
        it.i = body_end + end_marker.len;
        return .{ .label = label, .body = it.text[body_start..body_end] };
    }
};

/// Decodes a block body into newly allocated DER bytes.
pub fn decodeBody(gpa: Allocator, body: []const u8) (Error || Allocator.Error)![]u8 {
    // Encapsulated headers ("Proc-Type: ...") mark legacy encrypted keys.
    if (mem.findScalar(u8, body, ':') != null) return error.EncryptedPrivateKey;
    const buf = try gpa.alloc(u8, base64.calcSizeUpperBound(body.len));
    errdefer gpa.free(buf);
    const len = try base64.decode(buf, body);
    return gpa.realloc(buf, len);
}

/// DER certificates, leaf first, as read from a PEM chain.
pub const CertificateChain = struct {
    certs: []const []const u8,

    pub fn deinit(chain: CertificateChain, gpa: Allocator) void {
        for (chain.certs) |c| gpa.free(c);
        gpa.free(chain.certs);
    }
};

/// Every "CERTIFICATE" block of `text`, in order.
pub fn parseCertificateChain(gpa: Allocator, text: []const u8) (Error || Allocator.Error)!CertificateChain {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |c| gpa.free(c);
        list.deinit(gpa);
    }
    var it: Iterator = .{ .text = text };
    while (try it.next()) |block| {
        if (!mem.eql(u8, block.label, "CERTIFICATE")) continue;
        try list.ensureUnusedCapacity(gpa, 1);
        list.appendAssumeCapacity(try decodeBody(gpa, block.body));
    }
    if (list.items.len == 0) return error.NoPemBlock;
    return .{ .certs = try list.toOwnedSlice(gpa) };
}

/// The first private key block of `text`: "PRIVATE KEY" (PKCS#8),
/// "EC PRIVATE KEY" (SEC1) or "RSA PRIVATE KEY" (PKCS#1). Certificates in
/// the same file are skipped, so a combined cert+key file works.
pub fn parsePrivateKey(gpa: Allocator, text: []const u8) (Error || Allocator.Error)!PrivateKey {
    var it: Iterator = .{ .text = text };
    while (try it.next()) |block| {
        if (mem.eql(u8, block.label, "ENCRYPTED PRIVATE KEY")) return error.EncryptedPrivateKey;
        if (!mem.endsWith(u8, block.label, "PRIVATE KEY")) continue;
        const der = try decodeBody(gpa, block.body);
        defer {
            std.crypto.secureZero(u8, der);
            gpa.free(der);
        }
        return PrivateKey.fromDer(der, block.label);
    }
    return error.NoPemBlock;
}

/// A client certificate chain and its key, owned. Keep it alive (and in
/// place: `identity` borrows it) while connections are being set up.
pub const OwnedIdentity = struct {
    chain: CertificateChain,
    key: PrivateKey,

    pub fn identity(o: *const OwnedIdentity) Client.Identity {
        return .{ .chain = o.chain.certs, .key = &o.key };
    }

    pub fn deinit(o: *OwnedIdentity, gpa: Allocator) void {
        o.chain.deinit(gpa);
        std.crypto.secureZero(u8, mem.asBytes(&o.key));
    }
};

/// Builds an identity from the PEM text of a certificate chain and a key.
pub fn parseIdentity(gpa: Allocator, cert_pem: []const u8, key_pem: []const u8) (Error || Allocator.Error)!OwnedIdentity {
    const k = try parsePrivateKey(gpa, key_pem);
    return .{ .chain = try parseCertificateChain(gpa, cert_pem), .key = k };
}

pub const max_pem_file_len = 1 << 20;

/// Reads `cert_path` and `key_path` (relative to the cwd or absolute).
pub fn loadIdentity(gpa: Allocator, io: Io, cert_path: []const u8, key_path: []const u8) !OwnedIdentity {
    const cert_pem = try Io.Dir.cwd().readFileAlloc(io, cert_path, gpa, .limited(max_pem_file_len));
    defer gpa.free(cert_pem);
    const key_pem = try Io.Dir.cwd().readFileAlloc(io, key_path, gpa, .limited(max_pem_file_len));
    defer {
        std.crypto.secureZero(u8, key_pem);
        gpa.free(key_pem);
    }
    return parseIdentity(gpa, cert_pem, key_pem);
}

/// Adds every "CERTIFICATE" block of `text` to `bundle`, with std's rules:
/// expired and unparseable-algorithm certificates are skipped.
pub fn addCertsFromPem(
    bundle: *Certificate.Bundle,
    gpa: Allocator,
    now: Io.Timestamp,
    text: []const u8,
) (Error || Certificate.Bundle.ParseCertError || error{CertificateAuthorityBundleTooBig})!void {
    var it: Iterator = .{ .text = text };
    while (try it.next()) |block| {
        if (!mem.eql(u8, block.label, "CERTIFICATE")) continue;
        const upper = base64.calcSizeUpperBound(block.body.len);
        if (bundle.bytes.items.len + upper > std.math.maxInt(u32)) return error.CertificateAuthorityBundleTooBig;
        try bundle.bytes.ensureUnusedCapacity(gpa, upper);
        const start: u32 = @intCast(bundle.bytes.items.len);
        bundle.bytes.items.len += try base64.decode(bundle.bytes.unusedCapacitySlice(), block.body);
        try bundle.parseCert(gpa, start, now.toSeconds());
    }
}

pub const CaBundleOptions = struct {
    /// Start from the operating system's roots (`Bundle.rescan`).
    system_roots: bool = true,
    /// A PEM file of extra trusted CAs (the store's `ca-cert`).
    extra_ca_path: ?[]const u8 = null,
};

/// A CA bundle for `Client.Options.ca`: the system roots plus a custom CA.
pub fn loadCaBundle(gpa: Allocator, io: Io, now: Io.Timestamp, options: CaBundleOptions) !Certificate.Bundle {
    var bundle: Certificate.Bundle = .empty;
    errdefer bundle.deinit(gpa);
    if (options.system_roots) try bundle.rescan(gpa, io, now);
    if (options.extra_ca_path) |path| {
        const text = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * max_pem_file_len));
        defer gpa.free(text);
        // A CA file without certificates is a configuration mistake.
        if (mem.find(u8, text, "-----BEGIN CERTIFICATE-----") == null) return error.NoPemBlock;
        try addCertsFromPem(&bundle, gpa, now, text);
    }
    return bundle;
}

const testing = std.testing;
const testdata = @import("testdata.zig");

test "identity from a certificate and a key, in separate or combined files" {
    var id = try parseIdentity(testing.allocator, testdata.p256_cert, testdata.p256_sec1);
    defer id.deinit(testing.allocator);
    try testing.expectEqual(1, id.chain.certs.len);
    const parsed = try (Certificate{ .buffer = id.chain.certs[0], .index = 0 }).parse();
    try testing.expectEqualStrings("iets test CA", parsed.commonName());
    try testing.expect(id.identity().key.* == .ecdsa_p256);

    const combined = testdata.p256_cert ++ "\n" ++ testdata.p256_pkcs8 ++ "\n" ++ testdata.p256_cert;
    var id2 = try parseIdentity(testing.allocator, combined, combined);
    defer id2.deinit(testing.allocator);
    try testing.expectEqual(2, id2.chain.certs.len);
    try testing.expectEqualSlices(u8, &id.key.ecdsa_p256, &id2.key.ecdsa_p256);
}

test "PEM errors" {
    const gpa = testing.allocator;
    try testing.expectError(error.NoPemBlock, parsePrivateKey(gpa, testdata.p256_cert));
    try testing.expectError(error.NoPemBlock, parseCertificateChain(gpa, "no pem here"));
    try testing.expectError(error.InvalidPem, parseCertificateChain(gpa, "-----BEGIN CERTIFICATE-----\nAAAA\n"));
    try testing.expectError(error.EncryptedPrivateKey, parsePrivateKey(gpa,
        \\-----BEGIN ENCRYPTED PRIVATE KEY-----
        \\AAAA
        \\-----END ENCRYPTED PRIVATE KEY-----
    ));
    try testing.expectError(error.EncryptedPrivateKey, parsePrivateKey(gpa,
        \\-----BEGIN RSA PRIVATE KEY-----
        \\Proc-Type: 4,ENCRYPTED
        \\DEK-Info: AES-128-CBC,00000000000000000000000000000000
        \\
        \\AAAA
        \\-----END RSA PRIVATE KEY-----
    ));
    try testing.expectError(error.InvalidCharacter, parseCertificateChain(gpa,
        \\-----BEGIN CERTIFICATE-----
        \\A*AA
        \\-----END CERTIFICATE-----
    ));
}

test "CA bundle from PEM text verifies the certificate it holds" {
    const gpa = testing.allocator;
    var bundle: Certificate.Bundle = .empty;
    defer bundle.deinit(gpa);
    const now: Io.Timestamp = .fromNanoseconds(1_800_000_000 * std.time.ns_per_s); // 2027
    try addCertsFromPem(&bundle, gpa, now, "junk\n" ++ testdata.p256_cert ++ "\n" ++ testdata.p256_cert);
    try testing.expectEqual(1, bundle.map.count());

    var chain = try parseCertificateChain(gpa, testdata.p256_cert);
    defer chain.deinit(gpa);
    const parsed = try (Certificate{ .buffer = chain.certs[0], .index = 0 }).parse();
    try bundle.verify(parsed, now.toSeconds());
}

test "loadIdentity and loadCaBundle read files" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "ca.pem", .data = testdata.p256_cert });
    try tmp.dir.writeFile(io, .{ .sub_path = "key.pem", .data = testdata.rsa_pkcs1 });
    var path_buf: [3][128]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf[0], ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const ca_path = try std.fmt.bufPrint(&path_buf[1], "{s}/ca.pem", .{dir});
    const key_path = try std.fmt.bufPrint(&path_buf[2], "{s}/key.pem", .{dir});

    var id = try loadIdentity(gpa, io, ca_path, key_path);
    defer id.deinit(gpa);
    try testing.expect(id.key == .rsa);

    const now = Io.Timestamp.now(io, .real);
    var only_ca = try loadCaBundle(gpa, io, now, .{ .system_roots = false, .extra_ca_path = ca_path });
    defer only_ca.deinit(gpa);
    try testing.expectEqual(1, only_ca.map.count());

    var with_roots = try loadCaBundle(gpa, io, now, .{ .extra_ca_path = ca_path });
    defer with_roots.deinit(gpa);
    try testing.expect(with_roots.map.count() >= 1);
    try testing.expectError(error.NoPemBlock, loadCaBundle(gpa, io, now, .{ .system_roots = false, .extra_ca_path = key_path }));
}
