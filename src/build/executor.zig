//! The places a run may build, and which one takes a derivation.
//!
//! `builder` names one or more. A place carries what it will accept, declared
//! rather than probed: the worker protocol has no op that asks a daemon which
//! platforms it builds, and nix.conf's `builders` declares the same facts for
//! the same reason.
//!
//! The unit of placement is a root and everything under it, not a single
//! derivation. Both backends resolve a root's closure themselves (the daemon
//! from `BuildPathsWithResults`, the farm from its own scheduler), so a root
//! placed here has its whole closure built here. That keeps this stage free
//! of cross-place edges: nothing a place builds depends on something another
//! place holds. The cost is that two roots placed differently build what
//! they share twice (docs/reference/settings.md, `builder`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Diag = @import("../diag.zig").Diag;
const BuilderSpec = @import("../settings.zig").BuilderSpec;
const worker = @import("../remote/worker.zig");
const Transport = worker.Transport;

pub const Error = error{ Usage, OutOfMemory };

/// One place, its URL resolved to a transport.
pub const Place = struct {
    spec: BuilderSpec,
    transport: Transport,

    /// Whether this place accepts a derivation for `platform` that needs
    /// `features`. An undeclared constraint accepts anything, so one place
    /// that declares nothing takes every derivation, which is what a single
    /// `builder` has always done: the store itself refuses what it cannot
    /// build, and it is the only one that knows.
    pub fn takes(p: *const Place, platform: []const u8, features: []const []const u8) bool {
        const systems = p.spec.systems;
        const ours = p.spec.features;
        const sys_ok = systems.len == 0 or contains(systems, platform);
        if (!sys_ok) return false;
        if (ours.len == 0) return true;
        for (features) |f| if (!contains(ours, f)) return false;
        return true;
    }
};

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

/// Every place of this run, in the order `builder` named them.
pub const Places = struct {
    items: []const Place,

    /// Strings live in `arena`, as do the transports.
    pub fn parse(arena: Allocator, specs: []const BuilderSpec, system: []const u8, env: ?*const std.process.Environ.Map, d: *Diag) Error!Places {
        const places = try arena.alloc(Place, specs.len);
        for (specs, places) |spec, *p| {
            const t = Transport.parseChecked(arena, spec.url, system, env, d) catch |e| return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.Usage,
            };
            p.* = .{ .spec = spec, .transport = t orelse return unsupported(d, spec.url) };
        }
        if (places.len == 0) return d.fail(error.Usage, "builder names no place to build", .{});
        return .{ .items = places };
    }

    pub fn get(ps: Places, i: usize) *const Place {
        return &ps.items[i];
    }

    /// The first place that accepts the derivation. First, not best: this
    /// stage has no cost model, so the order `builder` gives is the policy.
    pub fn pick(ps: Places, platform: []const u8, features: []const []const u8) ?usize {
        for (ps.items, 0..) |*p, i| if (p.takes(platform, features)) return i;
        return null;
    }

    /// Why nothing took it, naming every place and what it declared.
    pub fn refused(ps: Places, d: *Diag, platform: []const u8, features: []const []const u8) Error {
        var buf: std.Io.Writer.Allocating = .init(d.gpa);
        defer buf.deinit();
        const w = &buf.writer;
        writeRefusal(w, ps, platform, features) catch return error.OutOfMemory;
        return d.fail(error.Usage, "{s}", .{buf.written()});
    }
};

fn writeRefusal(w: *std.Io.Writer, ps: Places, platform: []const u8, features: []const []const u8) std.Io.Writer.Error!void {
    try w.print("no builder takes a derivation for '{s}'", .{platform});
    if (features.len > 0) {
        try w.writeAll(" with ");
        try joinComma(w, features);
    }
    for (ps.items) |p| {
        try w.print("\n  {s}: ", .{p.spec.url});
        if (p.spec.systems.len == 0) try w.writeAll("any system") else try joinComma(w, p.spec.systems);
        if (p.spec.features.len > 0) {
            try w.writeAll(", features ");
            try joinComma(w, p.spec.features);
        }
    }
}

fn joinComma(w: *std.Io.Writer, items: []const []const u8) std.Io.Writer.Error!void {
    for (items, 0..) |s, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeAll(s);
    }
}

fn unsupported(d: *Diag, url: []const u8) Error {
    return d.fail(error.Usage, "unsupported builder '{s}': expected daemon, unix:///path, ssh-ng://[user@]host or grpc://host:port", .{url});
}

const testing = std.testing;

const T = struct {
    arena: std.heap.ArenaAllocator,
    d: Diag,

    fn init() T {
        return .{ .arena = .init(testing.allocator), .d = .init(testing.allocator) };
    }
    fn deinit(t: *T) void {
        t.d.deinit();
        t.arena.deinit();
    }
    fn places(t: *T, specs: []const BuilderSpec) !Places {
        return Places.parse(t.arena.allocator(), specs, "x86_64-linux", null, &t.d);
    }
};

fn mkSpec(url: []const u8, systems: []const []const u8, features: []const []const u8) BuilderSpec {
    return .{ .url = url, .systems = systems, .features = features };
}

test "one place declaring nothing takes everything" {
    var t: T = .init();
    defer t.deinit();
    const p = try t.places(&.{.bare("daemon")});
    try testing.expectEqual(0, p.pick("x86_64-linux", &.{}));
    try testing.expectEqual(0, p.pick("aarch64-darwin", &.{"big-parallel"}));
}

test "a declared system filters" {
    var t: T = .init();
    defer t.deinit();
    const p = try t.places(&.{ mkSpec("daemon", &.{"x86_64-linux"}, &.{}), mkSpec("ssh-ng://bld1", &.{"aarch64-linux"}, &.{}) });
    try testing.expectEqual(0, p.pick("x86_64-linux", &.{}));
    try testing.expectEqual(1, p.pick("aarch64-linux", &.{}));
    try testing.expectEqual(null, p.pick("x86_64-darwin", &.{}));
}

test "a feature the place lacks rules it out" {
    var t: T = .init();
    defer t.deinit();
    const p = try t.places(&.{ mkSpec("daemon", &.{"x86_64-linux"}, &.{"nixos-test"}), mkSpec("ssh-ng://bld1", &.{"x86_64-linux"}, &.{ "nixos-test", "kvm" }) });
    try testing.expectEqual(1, p.pick("x86_64-linux", &.{"kvm"}));
    try testing.expectEqual(0, p.pick("x86_64-linux", &.{"nixos-test"}));
    try testing.expectEqual(null, p.pick("x86_64-linux", &.{"big-parallel"}));
}

test "the first place that takes it wins" {
    var t: T = .init();
    defer t.deinit();
    const p = try t.places(&.{ .bare("daemon"), .bare("ssh-ng://bld1") });
    try testing.expectEqual(0, p.pick("x86_64-linux", &.{}));
}

test "a refusal names every place and what it declared" {
    var t: T = .init();
    defer t.deinit();
    const p = try t.places(&.{ mkSpec("daemon", &.{"x86_64-linux"}, &.{}), mkSpec("ssh-ng://bld1", &.{"aarch64-linux"}, &.{"kvm"}) });
    try testing.expectEqual(error.Usage, p.refused(&t.d, "x86_64-darwin", &.{"kvm"}));
    const e = t.d.message();
    try testing.expect(std.mem.indexOf(u8, e, "'x86_64-darwin' with kvm") != null);
    try testing.expect(std.mem.indexOf(u8, e, "daemon: x86_64-linux") != null);
    try testing.expect(std.mem.indexOf(u8, e, "ssh-ng://bld1: aarch64-linux, features kvm") != null);
}

test "an unsupported url says what is expected" {
    var t: T = .init();
    defer t.deinit();
    try testing.expectError(error.Usage, t.places(&.{.bare("s3://bucket")}));
    try testing.expect(std.mem.indexOf(u8, t.d.message(), "unsupported builder 's3://bucket'") != null);
}

test "no place at all is a usage error" {
    var t: T = .init();
    defer t.deinit();
    try testing.expectError(error.Usage, t.places(&.{}));
}
