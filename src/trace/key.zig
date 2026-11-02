//! The cache key: a hash of everything about the command that can change
//! the result, computed before evaluation.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const syntax = @import("../syntax.zig");

/// The hash of the sources this binary was built from (`build.zig`). Rust
/// iets's key holds its own build id, so the two binaries share a cache directory
/// and never read each other's entries.
pub const build_id = @import("build_options").build_id;

pub const Key = struct {
    h: Sha256,

    pub fn init(subcommand: []const u8) Key {
        var k: Key = .{ .h = .init(.{}) };
        k.field("build", build_id);
        k.field("cmd", subcommand);
        return k;
    }

    /// One tagged, length-prefixed field; the order of calls is part of the key.
    pub fn field(k: *Key, tag: []const u8, value: []const u8) void {
        k.h.update(std.mem.asBytes(&std.mem.nativeToLittle(u64, tag.len)));
        k.h.update(tag);
        k.h.update(std.mem.asBytes(&std.mem.nativeToLittle(u64, value.len)));
        k.h.update(value);
    }

    pub fn flag(k: *Key, tag: []const u8, on: bool) void {
        k.field(tag, &.{@intFromBool(on)});
    }

    /// The key as 64 lowercase hex digits.
    pub fn finish(k: *Key) [64]u8 {
        return std.fmt.bytesToHex(k.h.finalResult(), .lower);
    }
};

/// Whether an expression text holds a relative path literal, so its meaning
/// depends on cwd. A text that does not parse counts as relative (the key
/// then includes cwd, which is harmless).
pub fn hasRelativePath(gpa: std.mem.Allocator, src: []const u8) bool {
    var interner = syntax.Interner.init(gpa) catch return true;
    defer interner.deinit();
    var d: syntax.Diag = .init(gpa);
    defer d.deinit();
    var at: u32 = 0;
    var ast = syntax.parse(gpa, src, @fromBackingInt(0), &interner, &d, &at) catch return true;
    defer ast.deinit(gpa);
    for (ast.tags.items, ast.data.items) |t, x| {
        if (t == .path and x.path.kind == .relative) return true;
    }
    return false;
}

const testing = std.testing;

test "relative path detection" {
    const cases = [_]struct { []const u8, bool }{
        .{ "import ./x.nix", true },
        .{ "{ a = ../y; }", true },
        .{ "import /abs/x.nix", false },
        .{ "import <nixpkgs>", false },
        .{ "\"./not-a-path\"", false },
        .{ "let in (", true },
    };
    for (cases) |c| try testing.expectEqual(c[1], hasRelativePath(testing.allocator, c[0]));
}

test "the key is order and value sensitive" {
    var a: Key = .init("eval");
    a.field("x", "1");
    a.field("y", "2");
    var b: Key = .init("eval");
    b.field("y", "2");
    b.field("x", "1");
    var c: Key = .init("build");
    c.field("x", "1");
    c.field("y", "2");
    const fa = a.finish();
    const fb = b.finish();
    const fc = c.finish();
    try testing.expect(!std.mem.eql(u8, &fa, &fb));
    try testing.expect(!std.mem.eql(u8, &fa, &fc));
}
