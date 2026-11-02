//! `flake.lock` checks (lockfile.cc): the file must parse, and every node
//! reachable from the root must be locked. `call-flake.nix` does the rest.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const Value = json.Value;
const ObjectMap = json.ObjectMap;
const Diag = @import("../diag.zig").Diag;

/// lockfile.cc:LockFile::to_string of a lock without inputs, which Nix uses
/// for a flake that declares none and has no `flake.lock`.
pub const empty = "{\"nodes\":{\"root\":{}},\"root\":\"root\",\"version\":7}";

pub const Error = error{ Flake, OutOfMemory };

pub const Lock = struct {
    root: []const u8,
    json: Value,
    /// The nodes the root reaches, itself included, sorted.
    reached: []const []const u8,

    fn nodes(l: *const Lock) *const ObjectMap {
        // a pointer into the map, not to a copy of the value
        return &l.json.object.getPtr("nodes").?.object;
    }

    fn node(l: *const Lock, name: []const u8) ?*const ObjectMap {
        const n = l.nodes().getPtr(name) orelse return null;
        return if (n.* == .object) &n.object else null;
    }

    fn inputsOf(l: *const Lock, name: []const u8) ?*const ObjectMap {
        const n = l.node(name) orelse return null;
        const i = n.getPtr("inputs") orelse return null;
        return if (i.* == .object) &i.object else null;
    }

    /// The names of the root's inputs.
    pub fn rootInputs(l: *const Lock) []const []const u8 {
        const i = l.inputsOf(l.root) orelse return &.{};
        return i.keys();
    }

    pub fn hasRootInput(l: *const Lock, name: []const u8) bool {
        for (l.rootInputs()) |k| if (std.mem.eql(u8, k, name)) return true;
        return false;
    }

    pub const Reached = struct { name: []const u8, locked: *const ObjectMap };

    /// `(node name, locked attrs)` of every node but the root that the root
    /// reaches, as `nix flake prefetch-inputs` visits them.
    pub fn reachedInputs(l: *const Lock, a: Allocator) Allocator.Error![]Reached {
        var out: std.ArrayList(Reached) = .empty;
        for (l.reached) |n| {
            if (std.mem.eql(u8, n, l.root)) continue;
            const nd = l.node(n) orelse continue;
            const lk = nd.getPtr("locked") orelse continue;
            if (lk.* != .object) continue;
            try out.append(a, .{ .name = n, .locked = &lk.object });
        }
        return out.items;
    }

    /// Why the lock does not hold what `flake.nix` declares for input
    /// `name` of `node`, or null. A missing input is left to the caller.
    pub fn disagrees(l: *const Lock, a: Allocator, node_name: []const u8, name: []const u8, want: *const Declared) Allocator.Error!?[]const u8 {
        const spec = (l.inputsOf(node_name) orelse return null).get(name) orelse return null;
        switch (want.*) {
            .follows => |p| {
                if (spec == .array) {
                    const got = spec.array.items;
                    var same = got.len == p.len;
                    if (same) for (got, p) |g, w| {
                        if (g != .string or !std.mem.eql(u8, g.string, w)) same = false;
                    };
                    if (same) return null;
                }
                return try std.fmt.allocPrint(a, "follows '{f}' in flake.nix", .{Joined{ .parts = p }});
            },
            .ref => |r| {
                if (spec == .string) {
                    const n = l.node(spec.string) orelse return null;
                    const got = n.getPtr("original") orelse return null;
                    if (got.* != .object) return null;
                    if (sameNormal(&got.object, &r.original)) return null;
                }
                return try std.fmt.allocPrint(a, "is '{s}' in flake.nix", .{r.url});
            },
            .unknown => return null,
        }
    }

    /// The node input `name` of `node` names, unless it follows another.
    pub fn child(l: *const Lock, node_name: []const u8, name: []const u8) ?[]const u8 {
        const v = (l.inputsOf(node_name) orelse return null).get(name) orelse return null;
        return if (v == .string) v.string else null;
    }

    pub const NarName = struct { nar_hash: []const u8, name: []const u8 };

    /// `(narHash, node name)` of every locked node, for messages that name
    /// an input by what `fetchTree` receives.
    pub fn narHashNames(l: *const Lock, a: Allocator) Allocator.Error![]NarName {
        var out: std.ArrayList(NarName) = .empty;
        var it = l.nodes().iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.* != .object) continue;
            const lk = kv.value_ptr.object.get("locked") orelse continue;
            if (lk != .object) continue;
            const h = lk.object.get("narHash") orelse continue;
            if (h != .string) continue;
            try out.append(a, .{ .nar_hash = h.string, .name = kv.key_ptr.* });
        }
        return out.items;
    }
};

const Joined = struct {
    parts: []const []const u8,
    pub fn format(j: Joined, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (j.parts, 0..) |p, i| {
            if (i > 0) try w.writeByte('/');
            try w.writeAll(p);
        }
    }
};

/// What `flake.nix` declares for one input, as the lock records it.
pub const Declared = union(enum) {
    /// `follows`, split at `/`; empty is the root itself.
    follows: []const []const u8,
    /// `url` and its attributes, `dir` included: the lock's `original`.
    ref: struct { url: []const u8, original: ObjectMap },
    /// A form not compared: a path value, or the attributes of a reference.
    unknown,
};

/// `./sub` and `sub` are one relative path input.
fn normalPath(m: *const ObjectMap) ?[]const u8 {
    const t = m.get("type") orelse return null;
    if (t != .string or !std.mem.eql(u8, t.string, "path")) return null;
    const p = m.get("path") orelse return null;
    if (p != .string) return null;
    var s = p.string;
    while (std.mem.startsWith(u8, s, "./")) s = s[2..];
    return s;
}

/// The two objects are equal once a relative path is normal.
fn sameNormal(x: *const ObjectMap, y: *const ObjectMap) bool {
    if (x.count() != y.count()) return false;
    const px = normalPath(x);
    const py = normalPath(y);
    var it = x.iterator();
    while (it.next()) |kv| {
        const other = y.get(kv.key_ptr.*) orelse return false;
        if (std.mem.eql(u8, kv.key_ptr.*, "path") and px != null and py != null) {
            if (!std.mem.eql(u8, px.?, py.?)) return false;
            continue;
        }
        if (!jsonEql(kv.value_ptr.*, other)) return false;
    }
    return true;
}

/// Structural equality of two JSON values: objects compare as maps, so key
/// order does not matter.
pub fn jsonEql(a: Value, b: Value) bool {
    switch (a) {
        .null => return b == .null,
        .bool => |x| return b == .bool and b.bool == x,
        .integer => |x| return switch (b) {
            .integer => |y| x == y,
            .float => |y| @as(f64, @floatFromInt(x)) == y,
            else => false,
        },
        .float => |x| return switch (b) {
            .float => |y| x == y,
            .integer => |y| x == @as(f64, @floatFromInt(y)),
            else => false,
        },
        .number_string => |x| return b == .number_string and std.mem.eql(u8, x, b.number_string),
        .string => |x| return b == .string and std.mem.eql(u8, x, b.string),
        .array => |x| {
            if (b != .array or b.array.items.len != x.items.len) return false;
            for (x.items, b.array.items) |p, q| if (!jsonEql(p, q)) return false;
            return true;
        },
        .object => |x| {
            if (b != .object or b.object.count() != x.count()) return false;
            var it = x.iterator();
            while (it.next()) |kv| {
                const o = b.object.get(kv.key_ptr.*) orelse return false;
                if (!jsonEql(kv.value_ptr.*, o)) return false;
            }
            return true;
        },
    }
}

/// A node is locked when it has a `narHash` (fetchers.cc:isLocked) or is a
/// relative `path:` input resolved through its parent.
fn isLocked(n: Value) bool {
    if (n != .object) return false;
    const locked = n.object.get("locked") orelse return false;
    if (locked != .object) return false;
    const ty = locked.object.get("type") orelse return false;
    if (ty != .string) return false;
    if (locked.object.get("narHash")) |h| if (h == .string) return true;
    if (!std.mem.eql(u8, ty.string, "path")) return false;
    const p = locked.object.get("path") orelse return false;
    return p == .string and !std.mem.startsWith(u8, p.string, "/");
}

/// call-flake.nix:getInputByPath: follow a `follows` path from the root.
fn resolve(nodes: *const ObjectMap, root: []const u8, path: []const Value, depth: usize, d: *Diag) Error![]const u8 {
    if (depth > 64) return d.fail(error.Flake, "follow cycle", .{});
    var cur = root;
    for (path) |elem| {
        if (elem != .string) return d.fail(error.Flake, "follows path element is not a string", .{});
        const name = elem.string;
        const spec = blk: {
            const n = nodes.get(cur) orelse break :blk null;
            if (n != .object) break :blk null;
            const ins = n.object.get("inputs") orelse break :blk null;
            if (ins != .object) break :blk null;
            break :blk ins.object.get(name);
        } orelse return d.fail(error.Flake, "input '{s}' of node '{s}' is missing", .{ name, cur });
        cur = try resolveSpec(nodes, root, spec, depth + 1, d);
    }
    return cur;
}

fn resolveSpec(nodes: *const ObjectMap, root: []const u8, spec: Value, depth: usize, d: *Diag) Error![]const u8 {
    return switch (spec) {
        .string => |s| s,
        .array => |p| resolve(nodes, root, p.items, depth, d),
        else => d.fail(error.Flake, "input spec is neither a node name nor a follows path", .{}),
    };
}

/// Parses and checks a lock; everything it holds lives in `a`.
pub fn check(a: Allocator, bytes: []const u8, d: *Diag) Error!Lock {
    const root_v = json.parseFromSliceLeaky(Value, a, bytes, .{ .duplicate_field_behavior = .use_last }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return d.fail(error.Flake, "cannot parse: {s}", .{jsonText(e)}),
    };
    const version: u64 = blk: {
        if (root_v != .object) break :blk 0;
        const v = root_v.object.get("version") orelse break :blk 0;
        break :blk if (v == .integer and v.integer >= 0) @intCast(v.integer) else 0;
    };
    if (version < 5 or version > 7) return d.fail(error.Flake, "unsupported version {d}", .{version});
    const root = blk: {
        const r = root_v.object.get("root") orelse break :blk null;
        break :blk if (r == .string) r.string else null;
    } orelse return d.fail(error.Flake, "no root", .{});
    const nodes_v = root_v.object.getPtr("nodes") orelse return d.fail(error.Flake, "no nodes", .{});
    if (nodes_v.* != .object) return d.fail(error.Flake, "no nodes", .{});
    const nodes = &nodes_v.object;
    // a follows target is reached through its owner too, so only direct
    // edges extend the input path the hint names
    const Todo = struct { key: []const u8, path: []const u8 };
    var todo: std.ArrayList(Todo) = .empty;
    try todo.append(a, .{ .key = root, .path = "" });
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    while (todo.pop()) |t| {
        if ((try seen.getOrPut(a, t.key)).found_existing) continue;
        const n = nodes.get(t.key) orelse return d.fail(error.Flake, "node '{s}' is missing", .{t.key});
        if (!std.mem.eql(u8, t.key, root) and !isLocked(n)) {
            const fix = try std.fmt.allocPrint(a, "input '{s}' has no 'narHash' in flake.lock; run 'nix flake update {s}' to lock it again", .{ t.path, t.path });
            return d.failHint(error.Flake, fix, "node '{s}' is not locked", .{t.key});
        }
        if (n != .object) continue;
        const ins = n.object.get("inputs") orelse continue;
        if (ins != .object) continue;
        var it = ins.object.iterator();
        while (it.next()) |kv| {
            const to = try resolveSpec(nodes, root, kv.value_ptr.*, 0, d);
            if (kv.value_ptr.* == .string) {
                const p = if (t.path.len == 0) kv.key_ptr.* else try std.fmt.allocPrint(a, "{s}/{s}", .{ t.path, kv.key_ptr.* });
                try todo.append(a, .{ .key = to, .path = p });
            }
        }
    }
    const reached = try a.dupe([]const u8, seen.keys());
    std.mem.sort([]const u8, reached, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return .{ .root = root, .json = root_v, .reached = reached };
}

fn jsonText(e: anyerror) []const u8 {
    return switch (e) {
        error.UnexpectedEndOfInput => "EOF while parsing a value",
        error.SyntaxError => "syntax error",
        else => @errorName(e),
    };
}

const testing = std.testing;

const LOCK =
    \\{
    \\  "version": 7, "root": "root",
    \\  "nodes": {
    \\    "root": { "inputs": { "a": "a", "nixpkgs": ["a", "nixpkgs"], "p": "p" } },
    \\    "a": { "inputs": { "nixpkgs": "nixpkgs" },
    \\           "locked": { "type": "github", "owner": "x", "repo": "y", "rev": "0", "narHash": "sha256-AAAA" },
    \\           "original": { "type": "github", "owner": "x", "repo": "y" } },
    \\    "nixpkgs": { "locked": { "type": "github", "owner": "NixOS", "repo": "nixpkgs", "rev": "1", "narHash": "sha256-BBBB" },
    \\                 "original": { "type": "indirect", "id": "nixpkgs" } },
    \\    "p": { "locked": { "type": "path", "path": "./sub" }, "original": { "type": "path", "path": "./sub" }, "parent": [] }
    \\  }
    \\}
;

fn names(a: Allocator, rs: []const Lock.Reached) ![]const []const u8 {
    const out = try a.alloc([]const u8, rs.len);
    for (rs, out) |r, *o| o.* = r.name;
    return out;
}

fn expectNames(want: []const []const u8, got: []const []const u8) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "a complete lock passes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .init(a);
    const l = try check(a, LOCK, &d);
    try testing.expectEqualStrings("root", l.root);
    const ri = try a.dupe([]const u8, l.rootInputs());
    std.mem.sort([]const u8, ri, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    try expectNames(&.{ "a", "nixpkgs", "p" }, ri);
    try expectNames(&.{ "a", "nixpkgs", "p" }, try names(a, try l.reachedInputs(a)));
    const stale = try std.mem.replaceOwned(u8, a, LOCK, "\"nodes\": {", "\"nodes\": { \"x\": { \"locked\": { \"type\": \"github\", \"narHash\": \"sha256-C\" } },");
    try testing.expectEqual(@as(usize, 3), (try (try check(a, stale, &d)).reachedInputs(a)).len);
}

test "an empty lock has no inputs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .init(a);
    const l = try check(a, empty, &d);
    try testing.expectEqualStrings("root", l.root);
    try testing.expectEqual(@as(usize, 0), l.rootInputs().len);
    try testing.expectEqual(@as(usize, 0), (try l.reachedInputs(a)).len);
}

test "incomplete locks fail" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .init(a);
    const missing_node = try std.mem.replaceOwned(u8, a, LOCK, "\"a\": \"a\", ", "\"a\": \"b\", ");
    try testing.expectError(error.Flake, check(a, missing_node, &d));
    try testing.expect(std.mem.indexOf(u8, d.message(), "'b'") != null);
    const unlocked = try std.mem.replaceOwned(u8, a, LOCK, ", \"narHash\": \"sha256-BBBB\"", "");
    try testing.expectError(error.Flake, check(a, unlocked, &d));
    try testing.expectEqualStrings("node 'nixpkgs' is not locked", d.message());
    try testing.expectEqualStrings("input 'a/nixpkgs' has no 'narHash' in flake.lock; run 'nix flake update a/nixpkgs' to lock it again", d.hint.?);
    const bad_follows = try std.mem.replaceOwned(u8, a, LOCK, "[\"a\", \"nixpkgs\"]", "[\"a\", \"nope\"]");
    try testing.expectError(error.Flake, check(a, bad_follows, &d));
    try testing.expect(std.mem.indexOf(u8, d.message(), "nope") != null);
    const old = try std.mem.replaceOwned(u8, a, LOCK, "\"version\": 7", "\"version\": 4");
    try testing.expectError(error.Flake, check(a, old, &d));
    try testing.expectError(error.Flake, check(a, "{", &d));
}

fn obj(a: Allocator, text: []const u8) !ObjectMap {
    const v = try json.parseFromSliceLeaky(Value, a, text, .{});
    return v.object;
}

test "declared inputs must match the lock" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .init(a);
    const l = try check(a, LOCK, &d);
    const github: Declared = .{ .ref = .{ .url = "github:x/y", .original = try obj(a, "{ \"type\": \"github\", \"owner\": \"x\", \"repo\": \"y\" }") } };
    try testing.expect(try l.disagrees(a, "root", "a", &github) == null);
    const sub: Declared = .{ .ref = .{ .url = "./sub", .original = try obj(a, "{ \"type\": \"path\", \"path\": \"sub\" }") } };
    try testing.expect(try l.disagrees(a, "root", "p", &sub) == null);
    const follows: Declared = .{ .follows = &.{ "a", "nixpkgs" } };
    try testing.expect(try l.disagrees(a, "root", "nixpkgs", &follows) == null);
    try testing.expect(try l.disagrees(a, "root", "missing", &github) == null);
    try testing.expect(try l.disagrees(a, "root", "a", &.unknown) == null);
    const other: Declared = .{ .ref = .{ .url = "github:x/z", .original = try obj(a, "{ \"type\": \"github\", \"owner\": \"x\", \"repo\": \"z\" }") } };
    try testing.expect(try l.disagrees(a, "root", "a", &other) != null);
    try testing.expect(try l.disagrees(a, "root", "nixpkgs", &github) != null);
    try testing.expect(try l.disagrees(a, "root", "nixpkgs", &.{ .follows = &.{"a"} }) != null);
    try testing.expect(try l.disagrees(a, "root", "a", &.{ .follows = &.{} }) != null);
    try testing.expectEqualStrings("a", l.child("root", "a").?);
    try testing.expect(l.child("root", "nixpkgs") == null);
}
