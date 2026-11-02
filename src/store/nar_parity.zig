//! What the NAR code promises against real Nix: byte-identical archives and
//! the same hashes, on every shape the format has. Each test that needs
//! `nix-store` skips itself when it is not on `PATH`.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const Diag = @import("../diag.zig").Diag;
const nar = @import("nar.zig");
const Hash = @import("hash.zig").Hash;

const gpa = testing.allocator;

/// A tree that exercises every case the format has: unicode and awkward
/// names, empty files and directories, symlinks (a dangling one and one out
/// of the tree), the executable bit, contents on and off the 8-byte
/// boundary, and a file past the 64 KiB the writer buffers in one go.
fn awkwardTree(dir: Io.Dir) !void {
    const io = testing.io;
    const files = [_][2][]const u8{
        .{ "a", "" },
        .{ "b", "1234567" },
        .{ "c", "12345678" },
        .{ "d", "123456789" },
        .{ "é-accent", "héllo\n" },
        .{ "日本語/ファイル", "nihongo" },
        .{ " leading space", "x" },
        .{ "tab\there", "x" },
        .{ "-dash", "x" },
        .{ "z/y/x/w/v/deep", "deep" },
        .{ "run.sh", "#!/bin/sh\nexit 0\n" },
    };
    for (files) |f| {
        if (std.fs.path.dirname(f[0])) |p| try dir.createDirPath(io, p);
        try dir.writeFile(io, .{ .sub_path = f[0], .data = f[1] });
    }
    const big = try gpa.alloc(u8, 200_000);
    defer gpa.free(big);
    for (big, 0..) |*b, i| b.* = @intCast(i % 251);
    try dir.writeFile(io, .{ .sub_path = "big.bin", .data = big });
    try dir.setFilePermissions(io, "run.sh", .fromMode(0o755), .{});
    try dir.createDirPath(io, "emptydir");
    try dir.createDirPath(io, "dir/emptysub");
    try dir.symLink(io, "a", "link-a", .{});
    try dir.symLink(io, "nowhere-at-all", "link-dangling", .{});
    try dir.symLink(io, "../../outside", "dir/link-out", .{});
    try dir.symLink(io, "日本語", "link-unicode", .{});
}

/// `nix-store --dump path`, or null without `nix-store`.
fn nixDump(path: []const u8) !?[]u8 {
    const res = std.process.run(gpa, testing.io, .{ .argv = &.{ "nix-store", "--dump", path }, .stdout_limit = .unlimited }) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    defer gpa.free(res.stderr);
    if (res.term != .exited or res.term.exited != 0) {
        gpa.free(res.stdout);
        return error.NixStoreDumpFailed;
    }
    return res.stdout;
}

fn nixHash(path: []const u8) !?Hash {
    const out = (try nixDump(path)) orelse return null;
    defer gpa.free(out);
    return @import("hash.zig").hashBytes(.sha256, out);
}

const Tree = struct {
    tmp: testing.TmpDir,
    /// The absolute path of `tree`, for `nix-store`.
    abs: [:0]u8,

    fn make() !Tree {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "tree");
        var t = try tmp.dir.openDir(testing.io, "tree", .{});
        defer t.close(testing.io);
        try awkwardTree(t);
        const abs = try tmp.dir.realPathFileAlloc(testing.io, "tree", gpa);
        return .{ .tmp = tmp, .abs = abs };
    }

    fn deinit(t: *Tree) void {
        gpa.free(t.abs);
        t.tmp.cleanup();
    }

    fn dump(t: *Tree, sub: []const u8) ![]u8 {
        var d: Diag = .init(gpa);
        defer d.deinit();
        var out: Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        try nar.dumpPath(gpa, testing.io, t.tmp.dir, sub, &out.writer, nar.keep_all, &d);
        return out.toOwnedSlice();
    }

    fn hash(t: *Tree, sub: []const u8) !Hash {
        var d: Diag = .init(gpa);
        defer d.deinit();
        return nar.narHash(gpa, testing.io, t.tmp.dir, sub, &d);
    }
};

test "dump is byte-identical to nix-store --dump" {
    var t: Tree = try .make();
    defer t.deinit();
    const theirs = (try nixDump(t.abs)) orelse return error.SkipZigTest;
    defer gpa.free(theirs);
    const ours = try t.dump("tree");
    defer gpa.free(ours);
    try testing.expectEqual(theirs.len, ours.len);
    try testing.expectEqual(null, std.mem.indexOfDiff(u8, ours, theirs));
    try testing.expect((try t.hash("tree")).eql((try nixHash(t.abs)).?));
}

// Every subtree on its own, so a mismatch names the case.
test "every node hashes like nix" {
    var t: Tree = try .make();
    defer t.deinit();
    if (try nixHash(t.abs) == null) return error.SkipZigTest;
    var stack: std.ArrayList([]u8) = .empty;
    defer {
        for (stack.items) |p| gpa.free(p);
        stack.deinit(gpa);
    }
    try stack.append(gpa, try gpa.dupe(u8, "tree"));
    var checked: usize = 0;
    while (stack.pop()) |rel| {
        defer gpa.free(rel);
        const abs = try std.fs.path.join(gpa, &.{ std.fs.path.dirname(t.abs).?, rel });
        defer gpa.free(abs);
        const want = (try nixHash(abs)).?;
        (testing.expect((try t.hash(rel)).eql(want))) catch |e| {
            std.debug.print("NAR hash differs for {s}\n", .{rel});
            return e;
        };
        checked += 1;
        const st = try t.tmp.dir.statFile(testing.io, rel, .{ .follow_symlinks = false });
        if (st.kind != .directory) continue;
        var dir = try t.tmp.dir.openDir(testing.io, rel, .{ .iterate = true });
        defer dir.close(testing.io);
        var it = dir.iterate();
        while (try it.next(testing.io)) |e| try stack.append(gpa, try std.fs.path.join(gpa, &.{ rel, e.name }));
    }
    try testing.expect(checked > 20);
}

// The restore of our own dump reproduces the tree bit for bit.
test "restore round-trips the awkward tree" {
    var t: Tree = try .make();
    defer t.deinit();
    const theirs = (try nixHash(t.abs)) orelse return error.SkipZigTest;
    const archive = try t.dump("tree");
    defer gpa.free(archive);
    var d: Diag = .init(gpa);
    defer d.deinit();
    var rbuf: [nar.min_reader_buffer]u8 = undefined;
    var src: Io.Reader = .fixed(archive);
    var r = src.limited(.unlimited, &rbuf);
    try nar.restorePath(testing.io, &r.interface, t.tmp.dir, "restored", &d);
    const abs = try t.tmp.dir.realPathFileAlloc(testing.io, "restored", gpa);
    defer gpa.free(abs);
    try testing.expect((try nixHash(abs)).?.eql(theirs));
}

fn parseLen(bytes: []const u8, d: *Diag) !u64 {
    var buf: [nar.min_reader_buffer]u8 = undefined;
    var src: Io.Reader = .fixed(bytes);
    var r = src.limited(.unlimited, &buf);
    return nar.parseLength(&r.interface, d);
}

// The parse-only walk agrees with the archive's length and refuses what the
// restore would.
test "parse length matches the archive" {
    var t: Tree = try .make();
    defer t.deinit();
    const archive = try t.dump("tree");
    defer gpa.free(archive);
    var d: Diag = .init(gpa);
    defer d.deinit();
    try testing.expectEqual(archive.len, try parseLen(archive, &d));
    if (try nixDump(t.abs)) |theirs| {
        defer gpa.free(theirs);
        try testing.expectEqual(theirs.len, try parseLen(archive, &d));
    }
    try testing.expectError(error.BadNar, parseLen(archive[0 .. archive.len - 8], &d));
    const bad = try gpa.dupe(u8, archive);
    defer gpa.free(bad);
    bad[8] = 'X';
    try testing.expectError(error.BadNar, parseLen(bad, &d));
    try testing.expectError(error.BadNar, parseLen("nix-archive-2", &d));
}

// A name longer than NAME_MAX is refused, rather than failing later at the
// file's creation.
test "the reader caps names" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    const long: [300]u8 = @splat('a');
    for ([_][]const u8{ "nix-archive-1", "(", "type", "directory", "entry", "(", "name", &long }) |tok| {
        try bytes.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeToLittle(u64, tok.len)));
        try bytes.appendSlice(gpa, tok);
        try bytes.appendNTimes(gpa, 0, (8 - tok.len % 8) % 8);
    }
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var d: Diag = .init(gpa);
    defer d.deinit();
    var rbuf: [nar.min_reader_buffer]u8 = undefined;
    var src: Io.Reader = .fixed(bytes.items);
    var r = src.limited(.unlimited, &rbuf);
    try testing.expectError(error.BadNar, nar.restorePath(testing.io, &r.interface, tmp.dir, "dest", &d));
    try testing.expect(std.mem.indexOf(u8, d.message(), "too long") != null);
}
