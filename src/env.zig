//! The environment a command reads, handed in by the host: `iets` reads the
//! process environment, a host or a test hands in pairs of its own.

const std = @import("std");
const Map = std.process.Environ.Map;

pub const Env = struct {
    /// Null reads as an empty environment.
    map: ?*const Map = null,

    /// The process environment, as `main` received it.
    pub fn process(m: *const Map) Env {
        return .{ .map = m };
    }

    pub fn get(e: Env, name: []const u8) ?[]const u8 {
        const m = e.map orelse return null;
        return m.get(name);
    }

    /// `get`, with an empty value read as unset.
    pub fn nonEmpty(e: Env, name: []const u8) ?[]const u8 {
        const v = e.get(name) orelse return null;
        return if (v.len == 0) null else v;
    }
};

/// A map of `pairs`, owned by the caller (`Map.deinit`).
pub fn fromPairs(gpa: std.mem.Allocator, pairs: []const [2][]const u8) !Map {
    var m: Map = .init(gpa);
    errdefer m.deinit();
    for (pairs) |p| try m.put(p[0], p[1]);
    return m;
}

/// Every Nix configuration path points at /nonexistent.
pub fn isolated(gpa: std.mem.Allocator) !Map {
    return fromPairs(gpa, &.{
        .{ "NIX_CONF_DIR", "/nonexistent" },
        .{ "NIX_USER_CONF_FILES", "" },
        .{ "XDG_CONFIG_HOME", "/nonexistent" },
        .{ "XDG_CONFIG_DIRS", "/nonexistent" },
    });
}

/// `base` with `pairs` on top, owned by the caller.
pub fn with(gpa: std.mem.Allocator, base: Env, pairs: []const [2][]const u8) !Map {
    var m: Map = .init(gpa);
    errdefer m.deinit();
    if (base.map) |b| try m.putAll(b);
    for (pairs) |p| try m.put(p[0], p[1]);
    return m;
}

test "an empty value is unset for nonEmpty only" {
    var m = try isolated(std.testing.allocator);
    defer m.deinit();
    const e: Env = .process(&m);
    try std.testing.expectEqualStrings("", e.get("NIX_USER_CONF_FILES").?);
    try std.testing.expect(e.nonEmpty("NIX_USER_CONF_FILES") == null);
    try std.testing.expectEqualStrings("/nonexistent", e.nonEmpty("NIX_CONF_DIR").?);
    var w = try with(std.testing.allocator, e, &.{.{ "NIX_CONF_DIR", "/x" }});
    defer w.deinit();
    try std.testing.expectEqualStrings("/x", Env.process(&w).get("NIX_CONF_DIR").?);
    try std.testing.expect((Env{}).get("HOME") == null);
}
