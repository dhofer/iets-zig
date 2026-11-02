//! Where a tree comes from, and how it gets here.
//!
//! A `SourceRef` names one: a local directory, copied the way Nix copies it,
//! or a locked input, named by the `narHash` its lock gives. `tree` resolves
//! a reference into a `Tree`: a store path plus the attributes the tree
//! hashed to. The directory and working tree walks (`local`, `scm`), the
//! fetchers and the input store (`remote`, `treestore.zig`) are behind that
//! call, and `lock` is the `flake.lock` that names the locked references.
//!
//! Every name here comes from `treestore.storePath`: it is the content
//! address the input store keys its entries by, so nothing may compute a
//! store path for a tree another way.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Evaluator = @import("eval/Evaluator.zig");
const Error = Evaluator.Error;
const Pos = @import("syntax/pos.zig").Pos;
const Diag = @import("diag.zig").Diag;
const hash_mod = @import("store/hash.zig");
const Hash = hash_mod.Hash;
const StorePath = @import("store/path.zig").StorePath;

pub const attrs = @import("source/attrs.zig");
pub const proc = @import("source/proc.zig");
pub const scm = @import("source/scm.zig");
pub const lock = @import("source/lock.zig");
pub const local = @import("source/local.zig");
pub const remote = @import("source/remote.zig");

pub const AttrVal = attrs.AttrVal;
pub const Attrs = attrs.Attrs;
pub const strAttr = attrs.strAttr;
pub const Scm = scm.Scm;

pub fn intAttr(a: *const Attrs, name: []const u8) ?u64 {
    return switch (a.get(name) orelse return null) {
        .int => |n| n,
        else => null,
    };
}

pub fn boolAttr(a: *const Attrs, name: []const u8) ?bool {
    return switch (a.get(name) orelse return null) {
        .bool => |b| b,
        else => null,
    };
}

/// `flake:...`-style display of a reference for messages; not a parseable
/// ref.
pub fn toUrl(a: Allocator, m: *const Attrs) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    for (m.items(), 0..) |e, i| {
        if (i > 0) out.writer.writeByte('&') catch return error.OutOfMemory;
        writeVal(&out.writer, e.key, e.value) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice();
}

fn writeVal(w: *std.Io.Writer, k: []const u8, v: AttrVal) std.Io.Writer.Error!void {
    switch (v) {
        .str => |s| try w.print("{s}={s}", .{ k, s }),
        .bool => |b| try w.print("{s}={}", .{ k, b }),
        .int => |n| try w.print("{s}={d}", .{ k, n }),
    }
}

/// The attributes as JSON, for error messages and for Nix's `fromJSON`:
/// compact, keys in order, the bytes Rust iets writes.
pub fn attrsToJson(a: Allocator, m: *const Attrs) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    writeJson(&out.writer, m) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeJson(w: *std.Io.Writer, m: *const Attrs) std.Io.Writer.Error!void {
    try w.writeByte('{');
    for (m.items(), 0..) |e, i| {
        if (i > 0) try w.writeByte(',');
        try std.json.Stringify.encodeJsonString(e.key, .{}, w);
        try w.writeByte(':');
        switch (e.value) {
            .str => |s| try std.json.Stringify.encodeJsonString(s, .{}, w),
            .bool => |b| try w.print("{}", .{b}),
            .int => |n| try w.print("{d}", .{n}),
        }
    }
    try w.writeByte('}');
}

/// A `narHash` as a lock or a `fetchTree` call spells it: any form of a
/// SHA-256.
pub fn parseNarHash(s: []const u8, d: *Diag) hash_mod.Error!Hash {
    return Hash.parseAny(s, .sha256, d);
}

/// `%Y%m%d%H%M%S` of a Unix time in UTC (Howard Hinnant's civil_from_days).
pub fn lastModifiedDate(buf: *[14]u8, t: i64) []const u8 {
    const days = @divFloor(t, 86400);
    const secs = @mod(t, 86400);
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = @mod(z, 146097);
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const y = yoe + era * 400 + @as(i64, @intFromBool(m <= 2));
    return std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}", .{
        @as(u64, @intCast(y)),                     @as(u64, @intCast(m)),                               @as(u64, @intCast(d)),
        @as(u64, @intCast(@divTrunc(secs, 3600))), @as(u64, @intCast(@divTrunc(@mod(secs, 3600), 60))), @as(u64, @intCast(@mod(secs, 60))),
    }) catch buf;
}

/// Where a tree comes from.
pub const SourceRef = union(enum) {
    /// A local directory, copied whole (path.cc).
    path: []const u8,
    /// A directory inside the working tree of an SCM: only what the SCM
    /// tracks is copied, with the working tree's contents
    /// (git.cc:getAccessorFromWorkdir).
    tracked: struct { scm: *const Scm, root: []const u8, subdir: []const u8 },
    /// One revision of a local repository, which the SCM reads out of it
    /// (git.cc:getAccessorFromCommit). `git+file:///path?rev=…` names this,
    /// and it is the tree of the commit, not of the working tree beside it.
    commit: struct { scm: *const Scm, root: []const u8, rev: []const u8, subdir: []const u8 },
    /// A locked input: a `narHash` is known before anything is fetched, so
    /// the tree names itself and verifies itself.
    locked: Attrs,

    /// The `narHash` a locked reference carries, as the lock spells it.
    pub fn narHash(r: *const SourceRef) ?[]const u8 {
        return switch (r.*) {
            .locked => |*a| strAttr(a, "narHash"),
            else => null,
        };
    }

    pub fn eql(x: *const SourceRef, y: *const SourceRef) bool {
        if (std.meta.activeTag(x.*) != std.meta.activeTag(y.*)) return false;
        const e = std.mem.eql;
        return switch (x.*) {
            .path => |p| e(u8, p, y.path),
            .tracked => |t| t.scm == y.tracked.scm and e(u8, t.root, y.tracked.root) and e(u8, t.subdir, y.tracked.subdir),
            .commit => |c| c.scm == y.commit.scm and e(u8, c.root, y.commit.root) and e(u8, c.rev, y.commit.rev) and e(u8, c.subdir, y.commit.subdir),
            .locked => |*a| blk: {
                if (a.len() != y.locked.len()) break :blk false;
                for (a.items(), y.locked.items()) |p, q| if (!e(u8, p.key, q.key) or !p.value.eql(q.value)) break :blk false;
                break :blk true;
            },
        };
    }
};

/// The SCM and the root of a working tree that has a `revCount`.
pub const Counter = struct { scm: *const Scm, root: []const u8 };

/// A tree that is there: the store path it is named by, and the input
/// attributes it resolved to, `narHash` filled in (`emitTreeAttrs` renders
/// those). `subdir` is where a flake sits inside it.
pub const Tree = struct {
    path: StorePath,
    attrs: Attrs,
    subdir: []const u8 = "",
    /// The SCM and the root of a working tree that has a `revCount`. The
    /// attribute is not in `attrs`: the SCM counts when the evaluation reads
    /// it (`scm.revCount`).
    counter: ?Counter = null,

    pub fn rev(t: *const Tree) ?[]const u8 {
        return strAttr(&t.attrs, "rev");
    }
};

/// The tree a reference names, copied or fetched if it is not here yet.
/// The caller gets a store path that can be read, hashed and uploaded.
pub fn tree(ev: *Evaluator, r: *const SourceRef, pos: Pos) Error!Tree {
    return switch (r.*) {
        .path => |dir| local.pathSource(ev, dir, pos),
        .tracked => |t| local.trackedSource(ev, t.scm, t.root, t.subdir, pos),
        .commit => |c| local.commitSource(ev, c.scm, c.root, c.rev, c.subdir, pos),
        .locked => |*a| remote.locked(ev, a, pos),
    };
}

/// The context an `Scm` call of `ev` works in; its answers go to the
/// evaluator's arena.
pub fn scmCx(ev: *Evaluator, d: *Diag) scm.Cx {
    return .{
        .gpa = ev.gpa,
        .io = ev.io,
        .a = ev.local.arena.allocator(),
        .trace = ev.trace(),
        .env = if (ev.config.session) |s| s.env.map else null,
        .d = d,
    };
}

test {
    _ = attrs;
    _ = proc;
    _ = scm;
    _ = lock;
    _ = local;
    _ = remote;
}

test "dates" {
    var b: [14]u8 = undefined;
    try std.testing.expectEqualStrings("20260916132324", lastModifiedDate(&b, 1789565004));
    try std.testing.expectEqualStrings("20231114221320", lastModifiedDate(&b, 1700000000));
    try std.testing.expectEqualStrings("19700101000000", lastModifiedDate(&b, 0));
    try std.testing.expectEqualStrings("20000229000000", lastModifiedDate(&b, 951782400));
}

test "attrs as a url and as json" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m: Attrs = .{};
    try m.put(a, "type", .{ .str = "git" });
    try m.put(a, "url", .{ .str = "file:///a \"b\"" });
    try m.put(a, "submodules", .{ .bool = false });
    try m.put(a, "revCount", .{ .int = 3 });
    try std.testing.expectEqualStrings("revCount=3&submodules=false&type=git&url=file:///a \"b\"", try toUrl(a, &m));
    try std.testing.expectEqualStrings("{\"revCount\":3,\"submodules\":false,\"type\":\"git\",\"url\":\"file:///a \\\"b\\\"\"}", try attrsToJson(a, &m));
}
