//! What an operation produced, and the JSON that is its contract: the same
//! bytes `iets plumbing OP` writes and a porcelain `--json` writes. A value two frontends can emit belongs
//! here; how a terminal shows it belongs in `cli/render.zig`
//! (docs/explanation/plumbing-and-porcelain.md).
//!
//! The JSON is the bytes Rust iets writes: object keys sorted, no spaces.

const std = @import("std");
const text = @import("../syntax/text.zig");
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;
const log = @import("../log.zig");
const remote = @import("../remote.zig");
const Plan = remote.plan.Plan;
const worker = remote.worker;
const Outcome = @import("../build/dispatch.zig").Outcome;
const drvdiff = @import("../store/drvdiff.zig");

const str = text.writeJsonString;

fn strList(w: *Writer, items: []const []const u8) Writer.Error!void {
    try w.writeByte('[');
    for (items, 0..) |s, i| {
        if (i > 0) try w.writeByte(',');
        try str(w, s);
    }
    try w.writeByte(']');
}

/// What a build will build and what it will fetch: `plumbing missing`, and
/// `iets build --dry-run --json`.
pub const Missing = struct {
    will_build: []const []const u8,
    will_substitute: []const []const u8,
    unknown: []const []const u8,
    download_size: u64,
    nar_size: u64,
    /// `plumbing missing --check-cache-status`: the verdict per root, as
    /// raw JSON.
    roots: ?[]const u8 = null,

    /// The dispatcher's answer ordered: `willBuild` in the plan's order,
    /// references first, as Nix's reversed topoSortPaths gives it, and
    /// `willSubstitute` by the name part of the store path. In `a`.
    pub fn of(a: Allocator, m: worker.Missing, p: *const Plan) !Missing {
        var at: std.StringHashMapUnmanaged(usize) = .empty;
        for (p.drvs, 0..) |*o, i| try at.put(a, try std.fmt.allocPrint(a, "{f}", .{o.storePath()}), i);
        const Keyed = struct { key: usize, path: []const u8 };
        const wb = try a.alloc(Keyed, m.will_build.len);
        for (m.will_build, wb) |path, *k| k.* = .{ .key = at.get(path) orelse std.math.maxInt(usize), .path = path };
        // a stable sort keeps the daemon's order among the unplanned
        std.sort.insertion(Keyed, wb, {}, struct {
            fn lt(_: void, x: Keyed, y: Keyed) bool {
                return x.key < y.key;
            }
        }.lt);
        const will_build = try a.alloc([]const u8, wb.len);
        for (wb, will_build) |k, *o| o.* = k.path;
        const subst = try a.dupe([]const u8, m.will_substitute);
        std.mem.sort([]const u8, subst, {}, struct {
            fn name(s: []const u8) []const u8 {
                return if (s.len > 44) s[44..] else s;
            }
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return switch (std.mem.order(u8, name(x), name(y))) {
                    .lt => true,
                    .gt => false,
                    .eq => std.mem.lessThan(u8, x, y),
                };
            }
        }.lt);
        return .{
            .will_build = will_build,
            .will_substitute = subst,
            .unknown = m.unknown,
            .download_size = m.download_size,
            .nar_size = m.nar_size,
        };
    }

    pub fn json(m: *const Missing, w: *Writer) Writer.Error!void {
        try w.print("{{\"downloadSize\":{d},\"narSize\":{d},", .{ m.download_size, m.nar_size });
        if (m.roots) |r| try w.print("\"roots\":{s},", .{r});
        try w.writeAll("\"unknown\":");
        try strList(w, m.unknown);
        try w.writeAll(",\"willBuild\":");
        try strList(w, m.will_build);
        try w.writeAll(",\"willSubstitute\":");
        try strList(w, m.will_substitute);
        try w.writeByte('}');
    }
};

/// What became of every root: `plumbing build`, and `iets build --json`.
pub const Outcomes = struct {
    items: []const Outcome,
    /// `plumbing build --gc-root`: the links it made.
    gc_roots: ?[]const []const u8 = null,

    pub fn json(o: Outcomes, w: *Writer) Writer.Error!void {
        try w.writeByte('{');
        if (o.gc_roots) |g| {
            try w.writeAll("\"gcRoots\":");
            try strList(w, g);
            try w.writeByte(',');
        }
        try w.writeAll("\"outcomes\":[");
        for (o.items, 0..) |x, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"attr\":");
            try str(w, x.attr);
            try w.print(",\"drv\":\"{f}\",\"logTail\":", .{&x.drv});
            try strList(w, x.log_tail);
            try w.writeAll(",\"outputs\":{");
            for (x.outputs, 0..) |out, k| {
                if (k > 0) try w.writeByte(',');
                try str(w, out.name);
                try w.writeByte(':');
                try str(w, out.path);
            }
            try w.writeAll("},\"reason\":");
            if (x.reason) |r| try str(w, r) else try w.writeAll("null");
            try w.print(",\"success\":{}}}", .{x.success});
        }
        try w.writeAll("]}");
    }

    /// One store path per output: what a caller of `iets build` captures.
    pub fn text(o: Outcomes, w: *Writer) Writer.Error!void {
        for (o.items) |x| for (x.outputs) |out| try w.print("{s}\n", .{out.path});
    }
};

/// A hash and what it was taken of: `plumbing fetch`, and `iets prefetch
/// --json`.
pub const Fetched = struct {
    hash: []const u8,
    /// `"url"` or `"drvPath"`, and what it names.
    key: []const u8,
    origin: []const u8,

    pub fn json(f: Fetched, w: *Writer) Writer.Error!void {
        // keys sorted, as Rust iets writes them
        if (std.mem.lessThan(u8, f.key, "hash")) {
            try w.writeByte('{');
            try str(w, f.key);
            try w.writeByte(':');
            try str(w, f.origin);
            try w.writeAll(",\"hash\":");
            try str(w, f.hash);
        } else {
            try w.writeAll("{\"hash\":");
            try str(w, f.hash);
            try w.writeByte(',');
            try str(w, f.key);
            try w.writeByte(':');
            try str(w, f.origin);
        }
        try w.writeByte('}');
    }

    pub fn text(f: Fetched, w: *Writer) Writer.Error!void {
        try w.print("{s}\n", .{f.hash});
    }
};

/// What differs between two derivations, and its parts, for the frontends
/// that show one.
pub const Diff = drvdiff.Diff;
pub const DiffItem = drvdiff.Item;
pub const StorePath = @import("../store/path.zig").StorePath;

/// `plumbing drv-diff`, and `iets diff --json`. Only the root carries
/// `equal`; an input derivation under it is a node's shape.
pub fn diffJson(w: *Writer, d: *const Diff) Writer.Error!void {
    try diffNodeJson(w, d, true);
}

fn diffNodeJson(w: *Writer, d: *const Diff, root: bool) Writer.Error!void {
    try w.print("{{\"a\":\"{f}\",\"b\":\"{f}\",\"changes\":[", .{ &d.a, &d.b });
    for (d.items, 0..) |i, k| {
        if (k > 0) try w.writeByte(',');
        try w.writeAll("{\"a\":");
        try optStr(w, i.a);
        try w.writeAll(",\"b\":");
        try optStr(w, i.b);
        try w.writeAll(",\"key\":");
        try str(w, i.key);
        try w.writeAll(",\"what\":");
        try str(w, i.what);
        try w.writeByte('}');
    }
    try w.writeByte(']');
    if (d.cut) |c| try w.print(",\"cut\":\"{s}\"", .{c});
    if (root) try w.print(",\"equal\":{}", .{d.isEmpty()});
    if (d.changed.len > 0) {
        try w.writeAll(",\"inputDrvs\":[");
        for (d.changed, 0..) |*c, k| {
            if (k > 0) try w.writeByte(',');
            try diffNodeJson(w, c, false);
        }
        try w.writeByte(']');
    }
    try w.writeByte('}');
}

fn optStr(w: *Writer, s: ?[]const u8) Writer.Error!void {
    if (s) |x| try str(w, x) else try w.writeAll("null");
}

/// One package name whose versions differ between two closures.
pub const Change = struct {
    change: []const u8,
    name: []const u8,
    a: []const []const u8,
    b: []const []const u8,
};

/// Two output closures compared by package name and version, as nvd does:
/// `plumbing closure-diff`, and `iets diff --closure --json`.
pub const Closure = struct {
    a: []const u8,
    b: []const u8,
    packages: []const Change,

    pub fn isEmpty(c: *const Closure) bool {
        return c.packages.len == 0;
    }

    /// The names either closure has, with the versions each side holds,
    /// keeping the ones that differ.
    pub fn of(arena: Allocator, a: []const u8, b: []const u8, ca: Versions, cb: Versions) Allocator.Error!Closure {
        var out: std.ArrayList(Change) = .empty;
        var i: usize = 0;
        var j: usize = 0;
        while (i < ca.names.len or j < cb.names.len) {
            const ord: std.math.Order = if (i == ca.names.len) .gt else if (j == cb.names.len) .lt else std.mem.order(u8, ca.names[i].name, cb.names[j].name);
            const none: []const []const u8 = &.{};
            const x = if (ord != .gt) ca.names[i] else Versions.Entry{ .name = cb.names[j].name, .versions = none };
            const y = if (ord != .lt) cb.names[j] else Versions.Entry{ .name = ca.names[i].name, .versions = none };
            if (ord != .gt) i += 1;
            if (ord != .lt) j += 1;
            if (sameStrings(x.versions, y.versions)) continue;
            try out.append(arena, .{
                .change = if (x.versions.len == 0) "added" else if (y.versions.len == 0) "removed" else "changed",
                .name = x.name,
                .a = x.versions,
                .b = y.versions,
            });
        }
        return .{ .a = a, .b = b, .packages = out.items };
    }

    pub fn json(c: *const Closure, w: *Writer) Writer.Error!void {
        try w.writeAll("{\"a\":");
        try str(w, c.a);
        try w.writeAll(",\"b\":");
        try str(w, c.b);
        try w.print(",\"equal\":{},\"packages\":[", .{c.isEmpty()});
        for (c.packages, 0..) |p, k| {
            if (k > 0) try w.writeByte(',');
            try w.writeAll("{\"a\":");
            try strList(w, p.a);
            try w.writeAll(",\"b\":");
            try strList(w, p.b);
            try w.print(",\"change\":\"{s}\",\"name\":", .{p.change});
            try str(w, p.name);
            try w.writeByte('}');
        }
        try w.writeAll("]}");
    }
};

fn sameStrings(x: []const []const u8, y: []const []const u8) bool {
    if (x.len != y.len) return false;
    for (x, y) |p, q| if (!std.mem.eql(u8, p, q)) return false;
    return true;
}

/// Package names, sorted, each with its versions, sorted and unique.
pub const Versions = struct {
    names: []const Entry,

    pub const Entry = struct { name: []const u8, versions: []const []const u8 };

    /// From `(name, version)` pairs in any order, with duplicates.
    pub fn of(arena: Allocator, pairs: []NameVersion) Allocator.Error!Versions {
        std.mem.sortUnstable(NameVersion, pairs, {}, NameVersion.lessThan);
        var names: std.ArrayList(Entry) = .empty;
        var i: usize = 0;
        while (i < pairs.len) {
            var vs: std.ArrayList([]const u8) = .empty;
            var j = i;
            while (j < pairs.len and std.mem.eql(u8, pairs[j].name, pairs[i].name)) : (j += 1) {
                if (vs.items.len == 0 or !std.mem.eql(u8, vs.items[vs.items.len - 1], pairs[j].version))
                    try vs.append(arena, pairs[j].version);
            }
            try names.append(arena, .{ .name = pairs[i].name, .versions = vs.items });
            i = j;
        }
        return .{ .names = names.items };
    }
};

pub const NameVersion = struct {
    name: []const u8,
    version: []const u8,

    fn lessThan(_: void, x: NameVersion, y: NameVersion) bool {
        return switch (std.mem.order(u8, x.name, y.name)) {
            .lt => true,
            .gt => false,
            .eq => std.mem.lessThan(u8, x.version, y.version),
        };
    }
};

const testing = std.testing;

test "the outcomes contract" {
    var d: @import("../diag.zig").Diag = .init(testing.allocator);
    defer d.deinit();
    const sp = try @import("../store/path.zig").StorePath.parse("/nix/store/00000000000000000000000000000000-top.drv", &d);
    const items = [_]Outcome{.{ .attr = "top", .drv = sp, .success = true, .outputs = &.{.{ .name = "out", .path = "/nix/store/aaa-top" }} }};
    var buf: Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try (Outcomes{ .items = &items }).json(&buf.writer);
    try testing.expectEqualStrings(
        \\{"outcomes":[{"attr":"top","drv":"/nix/store/00000000000000000000000000000000-top.drv","logTail":[],"outputs":{"out":"/nix/store/aaa-top"},"reason":null,"success":true}]}
    , buf.written());
}

test "the missing contract" {
    const m: Missing = .{ .will_build = &.{"/nix/store/a.drv"}, .will_substitute = &.{}, .unknown = &.{}, .download_size = 1, .nar_size = 2 };
    var buf: Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try m.json(&buf.writer);
    try testing.expectEqualStrings(
        \\{"downloadSize":1,"narSize":2,"unknown":[],"willBuild":["/nix/store/a.drv"],"willSubstitute":[]}
    , buf.written());
}

test "the extra keys sort where serde puts them" {
    var buf: Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try (Outcomes{ .items = &.{}, .gc_roots = &.{"gc/x"} }).json(&buf.writer);
    try testing.expectEqualStrings(
        \\{"gcRoots":["gc/x"],"outcomes":[]}
    , buf.written());
    buf.clearRetainingCapacity();
    const m: Missing = .{ .will_build = &.{}, .will_substitute = &.{}, .unknown = &.{}, .download_size = 0, .nar_size = 0, .roots = "[]" };
    try m.json(&buf.writer);
    try testing.expectEqualStrings(
        \\{"downloadSize":0,"narSize":0,"roots":[],"unknown":[],"willBuild":[],"willSubstitute":[]}
    , buf.written());
    buf.clearRetainingCapacity();
    try (Fetched{ .hash = "sha256-x", .key = "drvPath", .origin = "/nix/store/a.drv" }).json(&buf.writer);
    try testing.expectEqualStrings(
        \\{"drvPath":"/nix/store/a.drv","hash":"sha256-x"}
    , buf.written());
}

test "the drv-diff contract" {
    var d: @import("../diag.zig").Diag = .init(testing.allocator);
    defer d.deinit();
    const a = try StorePath.fromBaseName("00000000000000000000000000000000-top.drv", &d);
    const b = try StorePath.fromBaseName("11111111111111111111111111111111-top.drv", &d);
    const ca = try StorePath.fromBaseName("00000000000000000000000000000000-dep.drv", &d);
    const cb = try StorePath.fromBaseName("11111111111111111111111111111111-dep.drv", &d);
    const items = [_]DiffItem{
        .{ .what = "platform", .a = "x86_64-linux", .b = "aarch64-linux" },
        .{ .what = "env", .key = "gone", .a = "", .b = null },
        .{ .what = "env", .key = "new", .a = null, .b = "a\nb" },
        .{ .what = "env", .key = "x", .a = "1", .b = "2" },
    };
    const child = [_]Diff{.{ .a = ca, .b = cb, .cut = "depth" }};
    var buf: Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try diffJson(&buf.writer, &.{ .a = a, .b = b, .items = &items, .changed = &child });
    try testing.expectEqualStrings(
        \\{"a":"/nix/store/00000000000000000000000000000000-top.drv","b":"/nix/store/11111111111111111111111111111111-top.drv","changes":[{"a":"x86_64-linux","b":"aarch64-linux","key":"","what":"platform"},{"a":"","b":null,"key":"gone","what":"env"},{"a":null,"b":"a\nb","key":"new","what":"env"},{"a":"1","b":"2","key":"x","what":"env"}],"equal":false,"inputDrvs":[{"a":"/nix/store/00000000000000000000000000000000-dep.drv","b":"/nix/store/11111111111111111111111111111111-dep.drv","changes":[],"cut":"depth"}]}
    , buf.written());
}

test "the closure-diff contract" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a_ = arena.allocator();
    var pa = [_]NameVersion{ .{ .name = "hello", .version = "2.12" }, .{ .name = "bash", .version = "5.2" }, .{ .name = "gone", .version = "1" }, .{ .name = "bash", .version = "5.2" } };
    var pb = [_]NameVersion{ .{ .name = "hello", .version = "2.13" }, .{ .name = "bash", .version = "5.2" }, .{ .name = "new", .version = "" }, .{ .name = "hello", .version = "2.12" } };
    const c = try Closure.of(a_, "A", "B", try Versions.of(a_, &pa), try Versions.of(a_, &pb));
    var buf: Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try c.json(&buf.writer);
    try testing.expectEqualStrings(
        \\{"a":"A","b":"B","equal":false,"packages":[{"a":["1"],"b":[],"change":"removed","name":"gone"},{"a":["2.12"],"b":["2.12","2.13"],"change":"changed","name":"hello"},{"a":[],"b":[""],"change":"added","name":"new"}]}
    , buf.written());
}
