//! Unpacking a downloaded tarball the way Nix does, so the NAR of the result
//! has the `narHash` the lock file names.
//!
//! tarfile.cc:unpackTarfileToSink walks the archive and feeds each member to a
//! sink; git-utils.cc:GitFileSystemObjectSinkImpl builds a git tree from them,
//! and tarball.cc:downloadTarball_ then calls `dereferenceSingletonDirectory`
//! before `treeHashToNarHash` hashes the tree. What survives into the hash is
//! therefore: directories (empty ones included, since the sink writes an empty
//! tree object for them), regular files with one bit of mode
//! (`archive_entry_mode() & S_IXUSR`, tarfile.cc:226), symlink targets, and
//! hard links resolved to a second entry with the target's blob and mode
//! (git-utils.cc:1348-1364). Everything else is an error (tarfile.cc:253). A
//! member listed twice keeps the last copy (git-utils.cc:1213, "only import
//! the latest version of a path").
//!
//! A fetch writes no tree: `spool.zig` indexes the archive and shares
//! `memberParts` with this module. `unpack` exists for the tests alone, as the
//! oracle the spool's NAR is held to (`spool matches the tree`).

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const Diag = @import("../diag.zig").Diag;
const tar = @import("tar.zig");
const spool = @import("spool.zig");

/// `CanonPath{name}` (tarfile.cc:204): the member path's components with any
/// root stripped, `.` dropped and `..` applied, each one copied into `a`. A
/// `..` at the top has nothing to remove, so no member ever names anything
/// outside the tree.
pub fn memberParts(a: Allocator, name: []const u8, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    var it = std.mem.tokenizeScalar(u8, name, '/');
    while (it.next()) |c| {
        if (std.mem.eql(u8, c, ".")) continue;
        if (std.mem.eql(u8, c, "..")) {
            _ = out.pop();
            continue;
        }
        try out.append(a, try a.dupe(u8, c));
    }
}

/// `memberParts` joined with `/`.
pub fn memberPath(a: Allocator, name: []const u8) Allocator.Error![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(a);
    try memberParts(a, name, &parts);
    return std.mem.join(a, "/", parts.items);
}

/// `root` joined with a member path, with the missing parents created. A parent
/// that exists and is not a directory is replaced, a symlink included: the sink
/// never follows one out of the tree, it overwrites it (git-utils.cc:addNode
/// emplaces a directory at every parent name).
fn makeParents(io: Io, root: Dir, parts: []const []const u8, buf: []u8) ![]const u8 {
    var len: usize = 0;
    for (parts, 0..) |c, i| {
        if (len > 0) {
            buf[len] = '/';
            len += 1;
        }
        @memcpy(buf[len..][0..c.len], c);
        len += c.len;
        if (i + 1 == parts.len) break;
        const at = buf[0..len];
        if (root.statFile(io, at, .{ .follow_symlinks = false })) |st| {
            if (st.kind != .directory) {
                try root.deleteFile(io, at);
                try root.createDir(io, at, .default_dir);
            }
        } else |_| try root.createDir(io, at, .default_dir);
    }
    return buf[0..len];
}

/// Whatever is at `at` goes away, unless it is a directory.
fn clear(io: Io, root: Dir, at: []const u8) !void {
    const st = root.statFile(io, at, .{ .follow_symlinks = false }) catch return;
    if (st.kind != .directory) try root.deleteFile(io, at);
}

/// Unpacks the tar `bytes` under `dest` and answers the directory to hash, in
/// `a`: `dest`, or its single entry when that is the only one and is a
/// directory (git-utils.cc:dereferenceSingletonDirectory).
pub fn unpack(a: Allocator, io: Io, bytes: []const u8, dest: []const u8, d: *Diag) ![]const u8 {
    try Dir.cwd().createDirPath(io, dest);
    var root = try Dir.cwd().openDir(io, dest, .{ .iterate = true });
    defer root.close(io);
    const Link = struct { key: []const u8, parts: []const []const u8, target: []const u8 };
    var links: std.ArrayList(Link) = .empty;
    var ar: tar.Archive = .{ .src = .{ .bytes = bytes } };
    var pbuf: [Dir.max_path_bytes]u8 = undefined;
    while (try ar.next(a, d)) |e_| {
        var e = e_;
        if (e.typeflag == tar.Type.pax_global) continue;
        const pax = try spool.paxSparse(a, &ar, &e, d);
        const name = if (pax) |s| s.name orelse try e.path(a) else try e.path(a);
        var parts: std.ArrayList([]const u8) = .empty;
        try memberParts(a, name, &parts);
        if (parts.items.len == 0) continue;
        switch (e.typeflag) {
            tar.Type.char, tar.Type.block_dev, tar.Type.fifo => return d.fail(error.BadArchive, "file '{s}' in tarball has unsupported file type {s}", .{ name, tar.Type.debugName(e.typeflag) }),
            else => {},
        }
        const at = try makeParents(io, root, parts.items, &pbuf);
        switch (e.typeflag) {
            tar.Type.directory => {
                if (root.statFile(io, at, .{ .follow_symlinks = false })) |st| {
                    if (st.kind != .directory) {
                        try root.deleteFile(io, at);
                        try root.createDir(io, at, .default_dir);
                    }
                } else |_| try root.createDir(io, at, .default_dir);
            },
            tar.Type.symlink => {
                const target = e.linkName() orelse return d.fail(error.BadArchive, "tarball symlink '{s}' has no target", .{at});
                try clear(io, root, at);
                try root.symLink(io, target, at, .{});
            },
            tar.Type.link => {
                const target = e.linkName() orelse return d.fail(error.BadArchive, "tarball link '{s}' has no target", .{at});
                const key = try std.mem.join(a, "\x00", parts.items);
                try links.append(a, .{ .key = key, .parts = parts.items, .target = try memberPath(a, target) });
            },
            else => {
                // libarchive gives every other type flag AE_IFREG (tarfile.cc:224)
                const exec = (e.mode() orelse 0o644) & 0o100 != 0;
                try clear(io, root, at);
                const f = try root.createFile(io, at, .{ .read = true });
                defer f.close(io);
                if (pax != null or e.typeflag == tar.Type.gnu_sparse) {
                    const size = if (pax) |s| s.size else e.size;
                    try spool.expand(a, io, &ar, &e, pax, f, 0, size);
                } else {
                    const data = bytes[@min(bytes.len, e.file_pos)..][0..@intCast(@min(e.size, bytes.len -| e.file_pos))];
                    try f.writePositionalAll(io, data, 0);
                }
                try f.setPermissions(io, .fromMode(if (exec) 0o755 else 0o644));
            },
        }
    }
    // the links in the order of their names, the last one for a name winning
    std.mem.sort(Link, links.items, {}, struct {
        fn lt(_: void, x: Link, y: Link) bool {
            return std.mem.lessThan(u8, x.key, y.key);
        }
    }.lt);
    for (links.items, 0..) |l, i| {
        if (i + 1 < links.items.len and std.mem.eql(u8, links.items[i + 1].key, l.key)) continue;
        const at = try makeParents(io, root, l.parts, &pbuf);
        const st = root.statFile(io, l.target, .{}) catch |err| return d.fail(err, "cannot link {s} to {s}: {t}", .{ at, l.target, err });
        if (st.kind == .directory)
            return d.fail(error.BadArchive, "tarball member '{s}' is a hard link to the directory '{s}'", .{ at, l.target });
        // a link carries no `id`, so it never takes a name a member claimed
        if (root.statFile(io, at, .{ .follow_symlinks = false })) |_| continue else |_| {}
        try Dir.copyFile(root, l.target, root, at, io, .{});
        try root.setFilePermissions(io, at, st.permissions, .{});
    }
    return singleton(a, io, root, dest);
}

/// git-utils.cc:dereferenceSingletonDirectory: one entry, and a directory.
fn singleton(a: Allocator, io: Io, root: Dir, dest: []const u8) ![]const u8 {
    var it = root.iterate();
    const first = (try it.next(io)) orelse return dest;
    const name = try a.dupe(u8, first.name);
    const kind = first.kind;
    if ((try it.next(io)) != null) return dest;
    if (kind != .directory) return dest;
    return std.fs.path.join(a, &.{ dest, name });
}

const testing = std.testing;
const T = tar.Type;

/// The unpacked tree, flattened: a directory is `dir`, a symlink `-> target`,
/// a file its contents with a leading `x` when it is executable.
fn flatten(a: Allocator, io: Io, root: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var dir = try Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    var lines: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |e| {
        const st = try dir.statFile(io, e.path, .{ .follow_symlinks = false });
        const line = switch (st.kind) {
            .directory => try std.fmt.allocPrint(a, "{s}=dir", .{e.path}),
            .sym_link => blk: {
                var b: [256]u8 = undefined;
                const n = try dir.readLink(io, e.path, &b);
                break :blk try std.fmt.allocPrint(a, "{s}=-> {s}", .{ e.path, b[0..n] });
            },
            else => blk: {
                const bytes = try dir.readFileAlloc(io, e.path, a, .unlimited);
                const x: []const u8 = if (st.permissions.toMode() & 0o100 != 0) "x" else "";
                break :blk try std.fmt.allocPrint(a, "{s}={s}{s}", .{ e.path, x, bytes });
            },
        };
        try lines.append(a, line);
    }
    std.mem.sort([]const u8, lines.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    for (lines.items) |l| {
        try out.appendSlice(a, l);
        try out.append(a, ';');
    }
    return out.items;
}

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    base: []const u8,
    d: Diag,

    fn init() !*Fixture {
        const f = try testing.allocator.create(Fixture);
        f.* = .{ .arena = .init(testing.allocator), .tmp = testing.tmpDir(.{}), .base = "", .d = .init(testing.allocator) };
        var buf: [Dir.max_path_bytes]u8 = undefined;
        f.base = try f.arena.allocator().dupe(u8, buf[0..try f.tmp.dir.realPath(testing.io, &buf)]);
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.d.deinit();
        f.tmp.cleanup();
        f.arena.deinit();
        testing.allocator.destroy(f);
    }

    fn run(f: *Fixture, sub: []const u8, members: []const tar.TestMember) ![]const u8 {
        const a = f.arena.allocator();
        const bytes = try tar.testTar(a, members);
        return unpack(a, testing.io, bytes, try std.fs.path.join(a, &.{ f.base, sub }), &f.d);
    }
};

test "one leading directory is stripped" {
    const f = try Fixture.init();
    defer f.deinit();
    const root = try f.run("x", &.{
        .{ .name = "repo-abc/", .t = T.directory, .mode = 0o755 },
        .{ .name = "repo-abc/flake.nix", .t = T.regular, .data = "{}\n" },
        .{ .name = "repo-abc/sub/", .t = T.directory, .mode = 0o755 },
    });
    try testing.expectEqualStrings("repo-abc", std.fs.path.basename(root));
    try testing.expectEqualStrings("flake.nix={}\n;sub=dir;", try flatten(f.arena.allocator(), testing.io, root));
}

test "the root is kept when it is not a single directory" {
    const f = try Fixture.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const two = try f.run("two", &.{
        .{ .name = "a/", .t = T.directory, .mode = 0o755 },
        .{ .name = "b", .t = T.regular, .data = "x" },
    });
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ f.base, "two" }), two);
    try testing.expectEqualStrings("a=dir;b=x;", try flatten(a, testing.io, two));
    const one = try f.run("one", &.{.{ .name = "only", .t = T.regular, .data = "x" }});
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ f.base, "one" }), one);
}

test "modes, symlinks, hard links and empty directories" {
    const f = try Fixture.init();
    defer f.deinit();
    const root = try f.run("x", &.{
        .{ .name = "t/", .t = T.directory, .mode = 0o755 },
        .{ .name = "t/run", .t = T.regular, .mode = 0o755, .data = "#!/bin/sh\n" },
        .{ .name = "t/plain", .t = T.regular, .data = "p" },
        .{ .name = "t/empty/", .t = T.directory, .mode = 0o700 },
        .{ .name = "t/link", .t = T.symlink, .mode = 0o777, .data = "plain" },
        .{ .name = "t/same", .t = T.link, .data = "t/plain" },
    });
    try testing.expectEqualStrings("empty=dir;link=-> plain;plain=p;run=x#!/bin/sh\n;same=p;", try flatten(f.arena.allocator(), testing.io, root));
}

test "a repeated member keeps the last copy" {
    const f = try Fixture.init();
    defer f.deinit();
    const root = try f.run("x", &.{
        .{ .name = "t/", .t = T.directory, .mode = 0o755 },
        .{ .name = "t/f", .t = T.regular, .data = "first" },
        .{ .name = "t/f", .t = T.regular, .mode = 0o755, .data = "second" },
    });
    try testing.expectEqualStrings("f=xsecond;", try flatten(f.arena.allocator(), testing.io, root));
}

test "a device, socket or fifo member is an error" {
    const f = try Fixture.init();
    defer f.deinit();
    try testing.expectError(error.BadArchive, f.run("y", &.{.{ .name = "dev", .t = T.fifo }}));
    try testing.expect(std.mem.indexOf(u8, f.d.message(), "unsupported file type Fifo") != null);
}

test "member names are made relative and cannot escape" {
    const cases = [_][2][]const u8{
        .{ "/a/b", "a/b" },
        .{ "./a", "a" },
        .{ "a/./b", "a/b" },
        .{ "a/../b", "b" },
        .{ "../outside", "outside" },
        .{ "t/../../esc", "esc" },
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for (cases) |c| try testing.expectEqualStrings(c[1], try memberPath(arena.allocator(), c[0]));
}
