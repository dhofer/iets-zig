//! Command-line arguments as UTF-8 text that keeps every byte. Nix reads
//! argv as bytes; a host that only has UTF-8 strings
//! (the library API) carries a byte `b` that is not UTF-8 as the character
//! U+10FF00 + `b`, and `bytes` maps it back where the bytes matter. The
//! command line of this port is bytes already and needs neither.

const std = @import("std");

const base: u21 = 0x10FF00;

/// `raw` as valid UTF-8: each byte of an invalid sequence becomes one
/// character U+10FF00 + byte.
pub fn encode(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, raw.len);
    var i: usize = 0;
    while (i < raw.len) {
        const n = std.unicode.utf8ByteSequenceLength(raw[i]) catch 0;
        if (n > 0 and i + n <= raw.len and std.unicode.utf8ValidateSlice(raw[i .. i + n])) {
            try out.appendSlice(gpa, raw[i .. i + n]);
            i += n;
            continue;
        }
        // The longest valid prefix of a broken sequence is invalid bytes
        // too, one character each, as Rust iets (`utf8_chunks`) maps it.
        var buf: [4]u8 = undefined;
        const k = std.unicode.utf8Encode(base + raw[i], &buf) catch unreachable;
        try out.appendSlice(gpa, buf[0..k]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

/// The bytes `encode` started from. A U+10FF80..U+10FFFF typed as text
/// also comes back as one byte.
pub fn bytes(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, s.len);
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepointSlice()) |cs| {
        const c = std.unicode.utf8Decode(cs) catch {
            try out.appendSlice(gpa, cs);
            continue;
        };
        if (c >= base + 0x80 and c <= base + 0xff) {
            try out.append(gpa, @intCast(c - base));
        } else try out.appendSlice(gpa, cs);
    }
    return out.toOwnedSlice(gpa);
}

test "every byte round-trips" {
    const gpa = std.testing.allocator;
    const raw = "/tmp/\xff\xfe.nix caf\xc3\xa9 \xc3";
    const s = try encode(gpa, raw);
    defer gpa.free(s);
    try std.testing.expect(std.unicode.utf8ValidateSlice(s));
    try std.testing.expect(std.mem.startsWith(u8, s, "/tmp/"));
    try std.testing.expect(std.mem.indexOf(u8, s, "café") != null);
    const back = try bytes(gpa, s);
    defer gpa.free(back);
    try std.testing.expectEqualStrings(raw, back);
    const e = try encode(gpa, "-E");
    defer gpa.free(e);
    try std.testing.expectEqualStrings("-E", e);
}
