//! Private keys for TLS client authentication: DER parsing (SEC1, PKCS#1,
//! PKCS#8) and the signatures CertificateVerify needs. std only verifies
//! RSA, so the RSA private operation (CRT, RFC 8017 §5.1.2) and the
//! EMSA-PSS / EMSA-PKCS1-v1_5 encodings are implemented here on std.crypto.ff.

const std = @import("std");
const crypto = std.crypto;
const mem = std.mem;
const tls = std.crypto.tls;
const Sha256 = crypto.hash.sha2.Sha256;
const Sha384 = crypto.hash.sha2.Sha384;
const Sha512 = crypto.hash.sha2.Sha512;
const Ed25519 = crypto.sign.Ed25519;
const Ecdsa = crypto.sign.ecdsa.Ecdsa;

/// Largest signature `sign*` produces: an RSA-4096 signature.
pub const max_signature_len = 512;

pub const ParseError = error{
    /// The DER structure is malformed or truncated.
    InvalidKeyEncoding,
    /// Well-formed, but not a key type or curve this client signs with
    /// (supported: ECDSA P-256/P-384, Ed25519, RSA 1024..4096 bits).
    UnsupportedKeyType,
};

pub const SignError = error{
    /// The key cannot produce `scheme`.
    UnsupportedSignatureScheme,
    /// The key does not satisfy the scheme's size requirements, or its
    /// components are inconsistent (RSA CRT result failed its check).
    InvalidPrivateKey,
} || crypto.errors.IdentityElementError || crypto.errors.NonCanonicalError;

pub const Rsa = struct {
    /// Big-endian components without leading zero bytes. CRT form only:
    /// `d` is not needed once dp, dq and qinv are known.
    n_buf: [512]u8,
    n_len: u16,
    e_buf: [8]u8,
    e_len: u8,
    p_buf: [256]u8,
    p_len: u16,
    q_buf: [256]u8,
    q_len: u16,
    dp_buf: [256]u8,
    dp_len: u16,
    dq_buf: [256]u8,
    dq_len: u16,
    qinv_buf: [256]u8,
    qinv_len: u16,

    pub fn n(k: *const Rsa) []const u8 {
        return k.n_buf[0..k.n_len];
    }
    pub fn e(k: *const Rsa) []const u8 {
        return k.e_buf[0..k.e_len];
    }

    /// Modulus size in bits.
    pub fn bits(k: *const Rsa) usize {
        const top = k.n_buf[0];
        return (@as(usize, k.n_len) - 1) * 8 + (8 - @clz(top));
    }
};

pub const PrivateKey = union(enum) {
    ecdsa_p256: [32]u8,
    ecdsa_p384: [48]u8,
    /// Kept as a key pair: Ed25519 signing needs the public key.
    ed25519: Ed25519.KeyPair,
    rsa: Rsa,

    /// Parses whichever DER encoding `der` holds, guided by the PEM label
    /// when known ("EC PRIVATE KEY", "RSA PRIVATE KEY", "PRIVATE KEY").
    pub fn fromDer(der: []const u8, pem_label: ?[]const u8) ParseError!PrivateKey {
        if (pem_label) |label| {
            if (mem.eql(u8, label, "EC PRIVATE KEY")) return fromSec1(der, null);
            if (mem.eql(u8, label, "RSA PRIVATE KEY")) return fromPkcs1(der);
            if (mem.eql(u8, label, "PRIVATE KEY")) return fromPkcs8(der);
            return error.UnsupportedKeyType;
        }
        return fromPkcs8(der) catch fromSec1(der, null) catch fromPkcs1(der);
    }

    /// PKCS#8 PrivateKeyInfo / OneAsymmetricKey (RFC 5208, RFC 5958).
    pub fn fromPkcs8(der: []const u8) ParseError!PrivateKey {
        var top: Der = .{ .bytes = der };
        var seq = try top.sub(tag_sequence);
        _ = try seq.next(tag_integer); // version 0 or 1
        var algo = try seq.sub(tag_sequence);
        const oid = try algo.next(tag_oid);
        const key_octets = try seq.next(tag_octet_string);
        // Optional attributes [0] and publicKey [1] are not needed.
        if (mem.eql(u8, oid, &oid_ec_public_key)) {
            const curve = try algo.next(tag_oid);
            return fromSec1(key_octets, curve);
        } else if (mem.eql(u8, oid, &oid_rsa_encryption)) {
            return fromPkcs1(key_octets);
        } else if (mem.eql(u8, oid, &oid_ed25519)) {
            // RFC 8410 §7: CurvePrivateKey ::= OCTET STRING, wrapped again.
            var inner: Der = .{ .bytes = key_octets };
            const seed = try inner.next(tag_octet_string);
            if (seed.len != Ed25519.KeyPair.seed_length) return error.InvalidKeyEncoding;
            const kp = Ed25519.KeyPair.generateDeterministic(seed[0..32].*) catch
                return error.InvalidKeyEncoding;
            return .{ .ed25519 = kp };
        }
        return error.UnsupportedKeyType;
    }

    /// SEC1 ECPrivateKey (RFC 5915). `curve_oid` comes from the PKCS#8
    /// AlgorithmIdentifier when the inner structure omits its parameters.
    pub fn fromSec1(der: []const u8, curve_oid: ?[]const u8) ParseError!PrivateKey {
        var top: Der = .{ .bytes = der };
        var seq = try top.sub(tag_sequence);
        const version = try seq.next(tag_integer);
        if (version.len != 1 or version[0] != 1) return error.InvalidKeyEncoding;
        const scalar = try seq.next(tag_octet_string);
        var curve = curve_oid;
        if (seq.peekTag() == tag_context_0) {
            var params = try seq.sub(tag_context_0);
            curve = try params.next(tag_oid);
        }
        const oid = curve orelse return error.InvalidKeyEncoding;
        if (mem.eql(u8, oid, &oid_prime256v1)) {
            const s = try leftPad(32, scalar);
            _ = Ecdsa(crypto.ecc.P256, Sha256).KeyPair.fromSecretKey(.{ .bytes = s }) catch
                return error.InvalidKeyEncoding;
            return .{ .ecdsa_p256 = s };
        } else if (mem.eql(u8, oid, &oid_secp384r1)) {
            const s = try leftPad(48, scalar);
            _ = Ecdsa(crypto.ecc.P384, Sha384).KeyPair.fromSecretKey(.{ .bytes = s }) catch
                return error.InvalidKeyEncoding;
            return .{ .ecdsa_p384 = s };
        }
        return error.UnsupportedKeyType;
    }

    /// PKCS#1 RSAPrivateKey (RFC 8017 §A.1.2).
    pub fn fromPkcs1(der: []const u8) ParseError!PrivateKey {
        var top: Der = .{ .bytes = der };
        var seq = try top.sub(tag_sequence);
        const version = try seq.next(tag_integer);
        // Version 1 means multi-prime, which needs the extra primes for CRT.
        if (version.len != 1 or version[0] != 0) return error.UnsupportedKeyType;
        var k: Rsa = undefined;
        const n_ = stripZeros(try seq.next(tag_integer));
        if (n_.len < 128 or n_.len > k.n_buf.len) return error.UnsupportedKeyType;
        k.n_len = @intCast(n_.len);
        @memcpy(k.n_buf[0..n_.len], n_);
        const e_ = stripZeros(try seq.next(tag_integer));
        if (e_.len == 0 or e_.len > k.e_buf.len) return error.InvalidKeyEncoding;
        k.e_len = @intCast(e_.len);
        @memcpy(k.e_buf[0..e_.len], e_);
        _ = try seq.next(tag_integer); // d: the CRT values below replace it
        inline for (.{ "p", "q", "dp", "dq", "qinv" }) |name| {
            const v = stripZeros(try seq.next(tag_integer));
            const buf = &@field(k, name ++ "_buf");
            if (v.len == 0 or v.len > buf.len) return error.InvalidKeyEncoding;
            @field(k, name ++ "_len") = @intCast(v.len);
            @memcpy(buf[0..v.len], v);
        }
        if (k.n_buf[0] == 0 or k.n_buf[k.n_len - 1] & 1 == 0) return error.InvalidKeyEncoding;
        return .{ .rsa = k };
    }

    /// The scheme this key signs a CertificateVerify with, given the
    /// server's `signature_algorithms` (raw big-endian u16 list).
    ///
    /// TLS 1.3 binds ECDSA schemes to curves and requires RSA-PSS
    /// (RFC 8446 §4.2.3). TLS 1.2 signs the handshake transcript hash,
    /// which this client keeps only with the cipher suite's hash, so the
    /// scheme's hash must equal `tls12_hash_len` (RFC 5246 §7.4.8); that
    /// also rules out Ed25519, which needs the whole message.
    pub fn chooseScheme(
        key: *const PrivateKey,
        version: tls.ProtocolVersion,
        tls12_hash_len: usize,
        offered: []const u8,
    ) ?tls.SignatureScheme {
        const S = tls.SignatureScheme;
        const tls13 = version == .tls_1_3;
        const prefs: []const S = switch (key.*) {
            .ecdsa_p256 => if (tls13) &.{.ecdsa_secp256r1_sha256} else switch (tls12_hash_len) {
                32 => &.{.ecdsa_secp256r1_sha256},
                48 => &.{.ecdsa_secp384r1_sha384},
                else => &.{},
            },
            .ecdsa_p384 => if (tls13) &.{.ecdsa_secp384r1_sha384} else switch (tls12_hash_len) {
                32 => &.{.ecdsa_secp256r1_sha256},
                48 => &.{.ecdsa_secp384r1_sha384},
                else => &.{},
            },
            .ed25519 => if (tls13) &.{.ed25519} else &.{},
            .rsa => if (tls13) &.{ .rsa_pss_rsae_sha256, .rsa_pss_rsae_sha384, .rsa_pss_rsae_sha512 } else switch (tls12_hash_len) {
                32 => &.{ .rsa_pss_rsae_sha256, .rsa_pkcs1_sha256 },
                48 => &.{ .rsa_pss_rsae_sha384, .rsa_pkcs1_sha384 },
                else => &.{},
            },
        };
        for (prefs) |want| {
            var i: usize = 0;
            while (i + 2 <= offered.len) : (i += 2) {
                if (mem.readInt(u16, offered[i..][0..2], .big) == @backingInt(want)) return want;
            }
        }
        return null;
    }

    /// Signs `msg` with `scheme` (hashing it with the scheme's hash).
    /// `seed` supplies the randomness for ECDSA noise and the PSS salt.
    pub fn signMessage(
        key: *const PrivateKey,
        scheme: tls.SignatureScheme,
        msg: []const u8,
        seed: *const [32]u8,
        out: *[max_signature_len]u8,
    ) SignError![]u8 {
        if (scheme == .ed25519) {
            const kp = switch (key.*) {
                .ed25519 => |kp| kp,
                else => return error.UnsupportedSignatureScheme,
            };
            const sig = kp.sign(msg, seed.*) catch return error.InvalidPrivateKey;
            out[0..64].* = sig.toBytes();
            return out[0..64];
        }
        var digest_buf: [64]u8 = undefined;
        const digest = switch (hashLen(scheme) orelse return error.UnsupportedSignatureScheme) {
            32 => d: {
                Sha256.hash(msg, digest_buf[0..32], .{});
                break :d digest_buf[0..32];
            },
            48 => d: {
                Sha384.hash(msg, digest_buf[0..48], .{});
                break :d digest_buf[0..48];
            },
            64 => d: {
                Sha512.hash(msg, digest_buf[0..64], .{});
                break :d digest_buf[0..64];
            },
            else => unreachable,
        };
        return key.signDigest(scheme, digest, seed, out);
    }

    /// Signs a digest the caller computed with `scheme`'s hash (TLS 1.2
    /// CertificateVerify signs the running transcript hash).
    pub fn signDigest(
        key: *const PrivateKey,
        scheme: tls.SignatureScheme,
        digest: []const u8,
        seed: *const [32]u8,
        out: *[max_signature_len]u8,
    ) SignError![]u8 {
        if ((hashLen(scheme) orelse return error.UnsupportedSignatureScheme) != digest.len)
            return error.UnsupportedSignatureScheme;
        switch (key.*) {
            .ecdsa_p256 => |*s| return ecdsaSign(crypto.ecc.P256, s, scheme, digest, seed, out),
            .ecdsa_p384 => |*s| return ecdsaSign(crypto.ecc.P384, s, scheme, digest, seed, out),
            .ed25519 => return error.UnsupportedSignatureScheme,
            .rsa => |*k| {
                const k_len: usize = k.n_len;
                const em = out[0..k_len];
                switch (scheme) {
                    .rsa_pkcs1_sha256, .rsa_pkcs1_sha384, .rsa_pkcs1_sha512 => try pkcs1Encode(digest, em),
                    .rsa_pss_rsae_sha256 => try pssEncode(Sha256, k, digest, seed, em),
                    .rsa_pss_rsae_sha384 => try pssEncode(Sha384, k, digest, seed, em),
                    .rsa_pss_rsae_sha512 => try pssEncode(Sha512, k, digest, seed, em),
                    else => return error.UnsupportedSignatureScheme,
                }
                try rsaPrivate(k, em);
                return em;
            },
        }
    }
};

fn hashLen(scheme: tls.SignatureScheme) ?usize {
    return switch (scheme) {
        .ecdsa_secp256r1_sha256, .rsa_pkcs1_sha256, .rsa_pss_rsae_sha256 => 32,
        .ecdsa_secp384r1_sha384, .rsa_pkcs1_sha384, .rsa_pss_rsae_sha384 => 48,
        .ecdsa_secp521r1_sha512, .rsa_pkcs1_sha512, .rsa_pss_rsae_sha512 => 64,
        else => null,
    };
}

fn ecdsaSign(
    comptime Curve: type,
    secret: *const [Curve.scalar.encoded_length]u8,
    scheme: tls.SignatureScheme,
    digest: []const u8,
    seed: *const [32]u8,
    out: *[max_signature_len]u8,
) SignError![]u8 {
    // The scheme fixes only the hash in TLS 1.2, so any curve/hash pairing
    // can be asked for; std's Ecdsa reduces the digest to the curve order.
    switch (scheme) {
        inline .ecdsa_secp256r1_sha256, .ecdsa_secp384r1_sha384, .ecdsa_secp521r1_sha512 => |s| {
            const Hash = switch (s) {
                .ecdsa_secp256r1_sha256 => Sha256,
                .ecdsa_secp384r1_sha384 => Sha384,
                else => Sha512,
            };
            const E = Ecdsa(Curve, Hash);
            const kp = try E.KeyPair.fromSecretKey(.{ .bytes = secret.* });
            // Noise on top of the deterministic nonce hardens against faults.
            var noise: [E.noise_length]u8 = undefined;
            var h: [64]u8 = undefined;
            Sha512.hash(seed, &h, .{});
            @memcpy(&noise, h[0..E.noise_length]);
            const sig = try kp.signPrehashed(digest[0..Hash.digest_length].*, noise);
            var der_buf: [E.Signature.der_encoded_length_max]u8 = undefined;
            const der = sig.toDer(&der_buf);
            @memcpy(out[0..der.len], der);
            return out[0..der.len];
        },
        else => return error.UnsupportedSignatureScheme,
    }
}

/// EMSA-PKCS1-v1_5 (RFC 8017 §9.2) over a precomputed digest.
fn pkcs1Encode(digest: []const u8, em: []u8) SignError!void {
    // DigestInfo DER prefixes, RFC 8017 §9.2 note 1.
    const prefix: []const u8 = switch (digest.len) {
        32 => &.{ 0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20 },
        48 => &.{ 0x30, 0x41, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02, 0x05, 0x00, 0x04, 0x30 },
        64 => &.{ 0x30, 0x51, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03, 0x05, 0x00, 0x04, 0x40 },
        else => return error.UnsupportedSignatureScheme,
    };
    const t_len = prefix.len + digest.len;
    if (em.len < t_len + 11) return error.InvalidPrivateKey;
    em[0] = 0x00;
    em[1] = 0x01;
    const ps_end = em.len - t_len - 1;
    @memset(em[2..ps_end], 0xff);
    em[ps_end] = 0x00;
    @memcpy(em[ps_end + 1 ..][0..prefix.len], prefix);
    @memcpy(em[em.len - digest.len ..], digest);
}

/// EMSA-PSS-ENCODE (RFC 8017 §9.1.1) with MGF1 and a salt as long as the
/// digest, which TLS requires (RFC 8446 §4.2.3). Writes the k-byte integer
/// representative: EM, left-padded with a zero byte when emLen < k.
fn pssEncode(comptime Hash: type, k: *const Rsa, m_hash: []const u8, seed: *const [32]u8, out: []u8) SignError!void {
    const h_len = Hash.digest_length;
    const em_bits = k.bits() - 1;
    const em_len = (em_bits + 7) / 8;
    if (em_len < h_len + h_len + 2) return error.InvalidPrivateKey;
    @memset(out[0 .. out.len - em_len], 0);
    const em = out[out.len - em_len ..];

    var salt: [h_len]u8 = undefined;
    {
        var xof: [64]u8 = undefined;
        var hs = Sha512.init(.{});
        hs.update("iets tls pss salt");
        hs.update(seed);
        hs.final(&xof);
        @memcpy(&salt, xof[0..h_len]);
    }

    var h: [h_len]u8 = undefined;
    {
        var hs = Hash.init(.{});
        hs.update(&@as([8]u8, @splat(0)));
        hs.update(m_hash);
        hs.update(&salt);
        hs.final(&h);
    }

    const db_len = em_len - h_len - 1;
    const db = em[0..db_len];
    @memset(db[0 .. db_len - h_len - 1], 0);
    db[db_len - h_len - 1] = 0x01;
    @memcpy(db[db_len - h_len ..], &salt);

    // MGF1 (RFC 8017 §B.2.1): db ^= Hash(h || counter) blocks.
    var counter: u32 = 0;
    var i: usize = 0;
    while (i < db_len) : (counter += 1) {
        var block: [h_len]u8 = undefined;
        var hs = Hash.init(.{});
        hs.update(&h);
        var c: [4]u8 = undefined;
        mem.writeInt(u32, &c, counter, .big);
        hs.update(&c);
        hs.final(&block);
        const n_ = @min(h_len, db_len - i);
        for (db[i..][0..n_], block[0..n_]) |*d, b| d.* ^= b;
        i += n_;
    }
    const unused_bits: u3 = @intCast(8 * em_len - em_bits);
    db[0] &= @as(u8, 0xff) >> unused_bits;

    @memcpy(em[db_len..][0..h_len], &h);
    em[em_len - 1] = 0xbc;
}

const RsaModulus = crypto.ff.Modulus(4096);
const HalfModulus = crypto.ff.Modulus(2048);

/// RSASP1 with the CRT (RFC 8017 §5.1.2, 2.b), in place on the k-byte
/// representative. The result is verified with the public exponent before
/// release: a fault in one CRT half would otherwise leak a factor of n.
fn rsaPrivate(k: *const Rsa, buf: []u8) SignError!void {
    const n_mod = RsaModulus.fromBytes(k.n(), .big) catch return error.InvalidPrivateKey;
    const p = HalfModulus.fromBytes(k.p_buf[0..k.p_len], .big) catch return error.InvalidPrivateKey;
    const q = HalfModulus.fromBytes(k.q_buf[0..k.q_len], .big) catch return error.InvalidPrivateKey;
    const c = RsaModulus.Fe.fromBytes(n_mod, buf, .big) catch return error.InvalidPrivateKey;

    const m1 = p.powWithEncodedExponent(p.reduce(c.v), k.dp_buf[0..k.dp_len], .big) catch
        return error.InvalidPrivateKey;
    const m2 = q.powWithEncodedExponent(q.reduce(c.v), k.dq_buf[0..k.dq_len], .big) catch
        return error.InvalidPrivateKey;
    const qinv = HalfModulus.Fe.fromBytes(p, k.qinv_buf[0..k.qinv_len], .big) catch
        return error.InvalidPrivateKey;
    const h = p.mul(qinv, p.sub(m1, p.reduce(m2.v)));

    // m = m2 + q*h is < n, so evaluating it mod n is exact.
    var tmp: [256]u8 = undefined;
    h.toBytes(&tmp, .big) catch return error.InvalidPrivateKey;
    const h_n = RsaModulus.Fe.fromBytes(n_mod, &tmp, .big) catch return error.InvalidPrivateKey;
    m2.toBytes(&tmp, .big) catch return error.InvalidPrivateKey;
    const m2_n = RsaModulus.Fe.fromBytes(n_mod, &tmp, .big) catch return error.InvalidPrivateKey;
    const q_n = RsaModulus.Fe.fromBytes(n_mod, k.q_buf[0..k.q_len], .big) catch
        return error.InvalidPrivateKey;
    const m = n_mod.add(m2_n, n_mod.mul(q_n, h_n));

    const check = n_mod.powWithEncodedPublicExponent(m, k.e(), .big) catch return error.InvalidPrivateKey;
    if (!check.eql(c)) return error.InvalidPrivateKey;
    m.toBytes(buf, .big) catch return error.InvalidPrivateKey;
    crypto.secureZero(u8, &tmp);
}

fn leftPad(comptime len: usize, bytes: []const u8) ParseError![len]u8 {
    const v = stripZeros(bytes);
    if (v.len > len) return error.InvalidKeyEncoding;
    var out: [len]u8 = @splat(0);
    @memcpy(out[len - v.len ..], v);
    return out;
}

fn stripZeros(bytes: []const u8) []const u8 {
    var i: usize = 0;
    while (i < bytes.len and bytes[i] == 0) i += 1;
    return bytes[i..];
}

const tag_integer = 0x02;
const tag_octet_string = 0x04;
const tag_oid = 0x06;
const tag_sequence = 0x30;
const tag_context_0 = 0xa0;

const oid_ec_public_key = [_]u8{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01 };
const oid_prime256v1 = [_]u8{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07 };
const oid_secp384r1 = [_]u8{ 0x2b, 0x81, 0x04, 0x00, 0x22 };
const oid_ed25519 = [_]u8{ 0x2b, 0x65, 0x70 };
const oid_rsa_encryption = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01 };

/// A bounds-checked DER reader; std's `Certificate.der` trusts its input.
const Der = struct {
    bytes: []const u8,
    i: usize = 0,

    fn peekTag(d: *const Der) ?u8 {
        return if (d.i < d.bytes.len) d.bytes[d.i] else null;
    }

    fn next(d: *Der, tag: u8) ParseError![]const u8 {
        if (d.i + 2 > d.bytes.len or d.bytes[d.i] != tag) return error.InvalidKeyEncoding;
        var len: usize = d.bytes[d.i + 1];
        d.i += 2;
        if (len & 0x80 != 0) {
            const n_ = len & 0x7f;
            if (n_ == 0 or n_ > 3 or d.i + n_ > d.bytes.len) return error.InvalidKeyEncoding;
            len = 0;
            for (d.bytes[d.i..][0..n_]) |b| len = len << 8 | b;
            d.i += n_;
        }
        if (len > d.bytes.len - d.i) return error.InvalidKeyEncoding;
        defer d.i += len;
        return d.bytes[d.i..][0..len];
    }

    fn sub(d: *Der, tag: u8) ParseError!Der {
        return .{ .bytes = try d.next(tag) };
    }
};

const testing = std.testing;
const testdata = @import("testdata.zig");
const pem = @import("pem.zig");

fn testKey(text: []const u8) !PrivateKey {
    return pem.parsePrivateKey(testing.allocator, text);
}

/// The subjectPublicKey bits of a "PUBLIC KEY" (SPKI) PEM, into `out`.
fn testPublicKey(text: []const u8, out: []u8) ![]u8 {
    var it: pem.Iterator = .{ .text = text };
    const der = try pem.decodeBody(testing.allocator, (try it.next()).?.body);
    defer testing.allocator.free(der);
    var top: Der = .{ .bytes = der };
    var spki = try top.sub(tag_sequence);
    _ = try spki.next(tag_sequence);
    const bits_ = try spki.next(0x03);
    @memcpy(out[0 .. bits_.len - 1], bits_[1..]);
    return out[0 .. bits_.len - 1];
}

/// Compares the meaningful bytes; the fixed buffers' tails are undefined.
fn testKeysEqual(a: *const PrivateKey, b: *const PrivateKey) bool {
    if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
    return switch (a.*) {
        .ecdsa_p256 => |s| mem.eql(u8, &s, &b.ecdsa_p256),
        .ecdsa_p384 => |s| mem.eql(u8, &s, &b.ecdsa_p384),
        .ed25519 => |kp| mem.eql(u8, &kp.secret_key.toBytes(), &b.ed25519.secret_key.toBytes()),
        .rsa => |*k| inline for (.{ "n", "e", "p", "q", "dp", "dq", "qinv" }) |f| {
            const x = @field(k, f ++ "_buf")[0..@field(k, f ++ "_len")];
            const y = @field(b.rsa, f ++ "_buf")[0..@field(b.rsa, f ++ "_len")];
            if (!mem.eql(u8, x, y)) break false;
        } else true,
    };
}

const test_seed: [32]u8 = @splat(7);
const test_msg = "TLS 1.3 CertificateVerify content stand-in";

test "ECDSA keys: SEC1 and PKCS#8 agree with OpenSSL's public key, signatures verify" {
    inline for (.{
        .{ testdata.p256_sec1, testdata.p256_pkcs8, testdata.p256_pub, crypto.ecc.P256, tls.SignatureScheme.ecdsa_secp256r1_sha256 },
        .{ testdata.p384_sec1, testdata.p384_pkcs8, testdata.p384_pub, crypto.ecc.P384, tls.SignatureScheme.ecdsa_secp384r1_sha384 },
    }) |case| {
        const sec1 = try testKey(case[0]);
        const pkcs8 = try testKey(case[1]);
        try testing.expect(testKeysEqual(&sec1, &pkcs8));
        const scalar = switch (sec1) {
            .ecdsa_p256 => |s| s[0..],
            .ecdsa_p384 => |s| s[0..],
            else => return error.TestUnexpectedResult,
        };
        const C = case[3];
        var pub_buf: [97]u8 = undefined;
        const pub_bytes = try testPublicKey(case[2], &pub_buf);

        // TLS 1.3 pairing: the curve's own hash over the message.
        const E = Ecdsa(C, if (C == crypto.ecc.P256) Sha256 else Sha384);
        const kp = try E.KeyPair.fromSecretKey(.{ .bytes = scalar[0..C.scalar.encoded_length].* });
        try testing.expectEqualSlices(u8, pub_bytes, &kp.public_key.toUncompressedSec1());
        var out: [max_signature_len]u8 = undefined;
        const sig = try sec1.signMessage(case[4], test_msg, &test_seed, &out);
        try (try E.Signature.fromDer(sig)).verify(test_msg, try E.PublicKey.fromSec1(pub_bytes));

        // TLS 1.2 pairing with the other hash: the scheme only names the hash.
        var digest: [48]u8 = undefined;
        Sha384.hash(test_msg, &digest, .{});
        const sig2 = try sec1.signDigest(.ecdsa_secp384r1_sha384, &digest, &test_seed, &out);
        const E2 = Ecdsa(C, Sha384);
        try (try E2.Signature.fromDer(sig2)).verifyPrehashed(digest, try E2.PublicKey.fromSec1(pub_bytes));
    }
}

test "Ed25519 PKCS#8 key signs verifiably" {
    const k = try testKey(testdata.ed25519_pkcs8);
    var pub_buf: [32]u8 = undefined;
    const pub_bytes = try testPublicKey(testdata.ed25519_pub, &pub_buf);
    try testing.expectEqualSlices(u8, pub_bytes, &k.ed25519.public_key.toBytes());
    var out: [max_signature_len]u8 = undefined;
    const sig = try k.signMessage(.ed25519, test_msg, &test_seed, &out);
    try Ed25519.Signature.fromBytes(sig[0..64].*).verify(test_msg, try Ed25519.PublicKey.fromBytes(pub_buf));
    try testing.expectError(error.UnsupportedSignatureScheme, k.signMessage(.ecdsa_secp256r1_sha256, test_msg, &test_seed, &out));
}

test "RSA keys: PKCS#1 and PKCS#8 agree, PSS and PKCS#1 v1.5 signatures verify" {
    const pkcs1 = try testKey(testdata.rsa_pkcs1);
    const pkcs8 = try testKey(testdata.rsa_pkcs8);
    try testing.expect(testKeysEqual(&pkcs1, &pkcs8));
    try testing.expectEqual(2048, pkcs1.rsa.bits());

    var pub_buf: [600]u8 = undefined;
    const spki = try testPublicKey(testdata.rsa_pub, &pub_buf);
    const RsaPub = crypto.Certificate.rsa.PublicKey;
    const parts = try RsaPub.parseDer(spki);
    try testing.expectEqualSlices(u8, parts.modulus, pkcs1.rsa.n());
    const public_key = try RsaPub.fromBytes(parts.exponent, parts.modulus);

    var out: [max_signature_len]u8 = undefined;
    const PSS = crypto.Certificate.rsa.PSSSignature;
    const PKCS1 = crypto.Certificate.rsa.PKCS1v1_5Signature;
    inline for (.{
        .{ tls.SignatureScheme.rsa_pss_rsae_sha256, Sha256, PSS },
        .{ tls.SignatureScheme.rsa_pss_rsae_sha384, Sha384, PSS },
        .{ tls.SignatureScheme.rsa_pss_rsae_sha512, Sha512, PSS },
        .{ tls.SignatureScheme.rsa_pkcs1_sha256, Sha256, PKCS1 },
        .{ tls.SignatureScheme.rsa_pkcs1_sha384, Sha384, PKCS1 },
    }) |case| {
        const sig = try pkcs1.signMessage(case[0], test_msg, &test_seed, &out);
        try testing.expectEqual(256, sig.len);
        try case[2].verify(256, sig[0..256], test_msg, public_key, case[1]);
        // The same through a caller-computed digest, as TLS 1.2 signs.
        var digest: [case[1].digest_length]u8 = undefined;
        case[1].hash(test_msg, &digest, .{});
        const sig2 = try pkcs1.signDigest(case[0], &digest, &test_seed, &out);
        try case[2].verify(256, sig2[0..256], test_msg, public_key, case[1]);
    }
}

test "RSA key with inconsistent CRT values is refused, not leaked" {
    var k = try testKey(testdata.rsa_pkcs1);
    k.rsa.dp_buf[0] ^= 1;
    var out: [max_signature_len]u8 = undefined;
    try testing.expectError(error.InvalidPrivateKey, k.signMessage(.rsa_pss_rsae_sha256, test_msg, &test_seed, &out));
}

test "chooseScheme follows the version's rules and the server's list" {
    const p256 = try testKey(testdata.p256_sec1);
    const rsa_key = try testKey(testdata.rsa_pkcs1);
    const ed = try testKey(testdata.ed25519_pkcs8);
    const all = tls.array(u16, tls.SignatureScheme, .{
        .ecdsa_secp256r1_sha256, .ecdsa_secp384r1_sha384, .rsa_pss_rsae_sha256,
        .rsa_pss_rsae_sha384,    .rsa_pkcs1_sha256,       .rsa_pkcs1_sha384,
        .ed25519,
    })[2..];
    try testing.expectEqual(.ecdsa_secp256r1_sha256, p256.chooseScheme(.tls_1_3, 32, all).?);
    try testing.expectEqual(.ecdsa_secp384r1_sha384, p256.chooseScheme(.tls_1_2, 48, all).?);
    try testing.expectEqual(.rsa_pss_rsae_sha256, rsa_key.chooseScheme(.tls_1_3, 48, all).?);
    try testing.expectEqual(.rsa_pss_rsae_sha384, rsa_key.chooseScheme(.tls_1_2, 48, all).?);
    try testing.expectEqual(.ed25519, ed.chooseScheme(.tls_1_3, 32, all).?);
    try testing.expectEqual(null, ed.chooseScheme(.tls_1_2, 32, all));
    const pkcs1_only = tls.array(u16, tls.SignatureScheme, .{.rsa_pkcs1_sha256})[2..];
    try testing.expectEqual(null, rsa_key.chooseScheme(.tls_1_3, 32, pkcs1_only));
    try testing.expectEqual(.rsa_pkcs1_sha256, rsa_key.chooseScheme(.tls_1_2, 32, pkcs1_only).?);
}

test "malformed DER is rejected" {
    var it: pem.Iterator = .{ .text = testdata.rsa_pkcs8 };
    const der = try pem.decodeBody(testing.allocator, (try it.next()).?.body);
    defer testing.allocator.free(der);
    var len: usize = 0;
    while (len < der.len) : (len += 7) {
        try testing.expect(std.meta.isError(PrivateKey.fromDer(der[0..len], "PRIVATE KEY")));
    }
    try testing.expectError(error.InvalidKeyEncoding, PrivateKey.fromDer(&.{ 0x30, 0x84, 0xff, 0xff, 0xff, 0xff }, null));
}
