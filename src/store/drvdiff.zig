//! What differs between two derivations, the way nix-diff explains a
//! rebuild: the local differences of a pair, then the input derivations
//! that differ, paired by name and recursed into (docs/reference/commands.md).

const std = @import("std");
const text = @import("../syntax/text.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Diag = @import("../diag.zig").Diag;
const path_mod = @import("path.zig");
const StorePath = path_mod.StorePath;
const drv_mod = @import("drv.zig");
const Derivation = drv_mod.Derivation;
const InputDrv = drv_mod.InputDrv;
const InputNode = drv_mod.InputNode;
const hash_mod = @import("hash.zig");
const log = @import("../log.zig");

pub const Error = drv_mod.Error;

/// One local difference. `what` names the part, `key` the entry inside it
/// (empty for a part that has one value), and `a`/`b` the two sides; null is
/// a side that has not got it. Text is valid UTF-8: env values are made so
/// as Rust iets's lossy conversion makes them.
pub const Item = struct {
    what: []const u8,
    key: []const u8 = "",
    a: ?[]const u8,
    b: ?[]const u8,
};

/// The difference between two derivations: what differs here, then the
/// input derivations that differ, paired by name.
pub const Diff = struct {
    a: StorePath,
    b: StorePath,
    items: []const Item = &.{},
    changed: []const Diff = &.{},
    /// Why the walk stopped here: "depth" or "shown above".
    cut: ?[]const u8 = null,

    pub fn isEmpty(d: *const Diff) bool {
        return d.items.len == 0 and d.changed.len == 0;
    }
};

/// The levels of `diff` that mean every level (`--all`).
pub const all_levels = std.math.maxInt(usize);

/// The difference between the derivations `a` and `b`, walking `depth`
/// levels of input derivations (`all_levels`: every level). `load` reads a
/// derivation: from the evaluation that made it, else from `/nix/store`.
/// The result, and every derivation read, live in `arena`.
pub fn diff(gpa: Allocator, arena: Allocator, load: drv_mod.Loader, a: StorePath, b: StorePath, depth: usize, d: *Diag) Error!Diff {
    var w: Walker = .{ .gpa = gpa, .arena = arena, .load = load, .d = d };
    defer w.seen.deinit(gpa);
    return w.walk(a, b, depth);
}

const Pair = struct { a: StorePath, b: StorePath };

const PairContext = struct {
    pub fn hash(_: PairContext, p: Pair) u64 {
        var h: std.hash.Wyhash = .init(0);
        h.update(p.a.baseName());
        h.update("/");
        h.update(p.b.baseName());
        return h.final();
    }
    pub fn eql(_: PairContext, x: Pair, y: Pair) bool {
        return x.a.eql(&y.a) and x.b.eql(&y.b);
    }
};

const Walker = struct {
    gpa: Allocator,
    arena: Allocator,
    load: drv_mod.Loader,
    d: *Diag,
    seen: std.HashMapUnmanaged(Pair, void, PairContext, std.hash_map.default_max_load_percentage) = .empty,

    fn walk(w: *Walker, pa: StorePath, pb: StorePath, depth: usize) Error!Diff {
        if (pa.eql(&pb)) return .{ .a = pa, .b = pb };
        if ((try w.seen.fetchPut(w.gpa, .{ .a = pa, .b = pb }, {})) != null)
            return .{ .a = pa, .b = pb, .cut = "shown above" };
        const a = try w.load.load(w.arena, pa, w.d);
        const b = try w.load.load(w.arena, pb, w.d);
        var v: std.ArrayList(Item) = .empty;
        try w.scalar(&v, "name", a.name, b.name);
        try w.scalar(&v, "platform", a.platform, b.platform);
        try w.scalar(&v, "builder", a.builder, b.builder);
        try w.scalar(&v, "args", try w.args(a.args), try w.args(b.args));
        try w.entry(&v, "structured attrs", "", a.structured_attrs, b.structured_attrs);
        try w.outputs(&v, &a, &b);
        try w.env(&v, &a, &b);
        try w.oneSided(&v, "input source", a.input_srcs, b.input_srcs, true);
        try w.oneSided(&v, "input source", b.input_srcs, a.input_srcs, false);

        const p = try pairInputs(w.gpa, w.arena, a.input_drvs, b.input_drvs);
        for (p.removed) |x| try w.entry(&v, "input drv", "", try w.full(x), null);
        for (p.added) |y| try w.entry(&v, "input drv", "", null, try w.full(y));
        var changed: std.ArrayList(Diff) = .empty;
        for (p.pairs) |xy| {
            var c = if (depth == 0)
                Diff{ .a = xy.a, .b = xy.b, .cut = "depth" }
            else
                try w.walk(xy.a, xy.b, depth - 1);
            var ci: std.ArrayList(Item) = .fromOwnedSlice(@constCast(c.items));
            try w.entry(&ci, "wanted", "", try w.wanted(findInput(a.input_drvs, xy.a)), try w.wanted(findInput(b.input_drvs, xy.b)));
            c.items = ci.items;
            if (!c.isEmpty() or c.cut != null) try changed.append(w.arena, c);
        }
        return .{ .a = pa, .b = pb, .items = v.items, .changed = changed.items };
    }

    fn scalar(w: *Walker, v: *std.ArrayList(Item), what: []const u8, a: []const u8, b: []const u8) Allocator.Error!void {
        return w.entry(v, what, "", a, b);
    }

    fn entry(w: *Walker, v: *std.ArrayList(Item), what: []const u8, key: []const u8, a: ?[]const u8, b: ?[]const u8) Allocator.Error!void {
        const same = if (a != null and b != null) std.mem.eql(u8, a.?, b.?) else a == null and b == null;
        if (!same) try v.append(w.arena, .{ .what = what, .key = key, .a = a, .b = b });
    }

    fn full(w: *Walker, p: StorePath) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(w.arena, "{f}", .{&p});
    }

    /// The builder's args, one quoted arg per line, so a long command line
    /// diffs line by line.
    fn args(w: *Walker, v: []const []const u8) Allocator.Error![]const u8 {
        var out: Writer.Allocating = .init(w.arena);
        for (v) |s| {
            writeDebug(&out.writer, s) catch return error.OutOfMemory;
            out.writer.writeByte('\n') catch return error.OutOfMemory;
        }
        return out.written();
    }

    fn outputs(w: *Walker, v: *std.ArrayList(Item), a: *const Derivation, b: *const Derivation) Allocator.Error!void {
        var i: usize = 0;
        var j: usize = 0;
        while (i < a.outputs.len or j < b.outputs.len) {
            const ord: std.math.Order = if (i == a.outputs.len) .gt else if (j == b.outputs.len) .lt else std.mem.order(u8, a.outputs[i].name, b.outputs[j].name);
            switch (ord) {
                // an input-addressed output path differs whenever anything
                // else does, so only a fixed or content-addressed one is compared
                .eq => {
                    const n = a.outputs[i].name;
                    try w.entry(v, "output", n, try w.fixed(a.outputs[i].output), try w.fixed(b.outputs[j].output));
                    i += 1;
                    j += 1;
                },
                .lt => {
                    try w.entry(v, "output", "", a.outputs[i].name, null);
                    i += 1;
                },
                .gt => {
                    try w.entry(v, "output", "", null, b.outputs[j].name);
                    j += 1;
                },
            }
        }
    }

    /// A fixed or content-addressed output, as text; null for an
    /// input-addressed or deferred one.
    fn fixed(w: *Walker, o: drv_mod.Output) Allocator.Error!?[]const u8 {
        return switch (o) {
            .fixed => |f| {
                var out: Writer.Allocating = .init(w.arena);
                out.writer.writeAll(f.method.prefix()) catch return error.OutOfMemory;
                hash_mod.writeBase16(&out.writer, f.hash.bytes()) catch return error.OutOfMemory;
                return out.written();
            },
            .ca_floating => |f| try std.fmt.allocPrint(w.arena, "{s}{s}", .{ f.method.prefix(), f.algo.name() }),
            .input_addressed, .deferred => null,
        };
    }

    fn env(w: *Walker, v: *std.ArrayList(Item), a: *const Derivation, b: *const Derivation) Allocator.Error!void {
        // the env entry named after an output holds that output's path, which
        // differs whenever anything else does (nix-diff leaves it out too), and
        // `env name` is the derivation's own name, which the `name` item said
        const hide_name = echoesName(a) and echoesName(b);
        const ea = a.env.items;
        const eb = b.env.items;
        var i: usize = 0;
        var j: usize = 0;
        while (true) {
            while (i < ea.len and !keep(a, b, hide_name, ea[i].key)) i += 1;
            while (j < eb.len and !keep(a, b, hide_name, eb[j].key)) j += 1;
            if (i == ea.len and j == eb.len) return;
            const ord: std.math.Order = if (i == ea.len) .gt else if (j == eb.len) .lt else std.mem.order(u8, ea[i].key, eb[j].key);
            switch (ord) {
                .eq => {
                    try w.entry(v, "env", ea[i].key, try text.lossyAlloc(w.arena, ea[i].value), try text.lossyAlloc(w.arena, eb[j].value));
                    i += 1;
                    j += 1;
                },
                .lt => {
                    try w.entry(v, "env", ea[i].key, try text.lossyAlloc(w.arena, ea[i].value), null);
                    i += 1;
                },
                .gt => {
                    try w.entry(v, "env", eb[j].key, null, try text.lossyAlloc(w.arena, eb[j].value));
                    j += 1;
                },
            }
        }
    }

    /// The paths of `x` that `y` has not got, in order; `left` says which
    /// side `x` is.
    fn oneSided(w: *Walker, v: *std.ArrayList(Item), what: []const u8, x: []const StorePath, y: []const StorePath, left: bool) Allocator.Error!void {
        var j: usize = 0;
        for (x) |p| {
            while (j < y.len and y[j].order(&p) == .lt) j += 1;
            if (j < y.len and y[j].eql(&p)) continue;
            const s = try w.full(p);
            if (left) try w.entry(v, what, "", s, null) else try w.entry(v, what, "", null, s);
        }
    }

    fn wanted(w: *Walker, n: InputNode) Allocator.Error!?[]const u8 {
        return try std.mem.join(w.arena, ",", n.outputs);
    }
};

fn echoesName(d: *const Derivation) bool {
    const v = d.envGet("name") orelse return false;
    return std.mem.eql(u8, v, d.name);
}

fn keep(a: *const Derivation, b: *const Derivation, hide_name: bool, k: []const u8) bool {
    return (a.output(k) == null or b.output(k) == null) and !(hide_name and std.mem.eql(u8, k, "name"));
}

fn findInput(inputs: []const InputDrv, p: StorePath) InputNode {
    for (inputs) |in| if (in.path.eql(&p)) return in.node;
    unreachable;
}

fn nodeEql(x: InputNode, y: InputNode) bool {
    if (x.outputs.len != y.outputs.len or x.children.len != y.children.len) return false;
    for (x.outputs, y.outputs) |p, q| if (!std.mem.eql(u8, p, q)) return false;
    for (x.children, y.children) |p, q|
        if (!std.mem.eql(u8, p.name, q.name) or !nodeEql(p.node, q.node)) return false;
    return true;
}

fn lookup(inputs: []const InputDrv, p: *const StorePath) ?InputNode {
    const i = std.sort.binarySearch(InputDrv, inputs, p, struct {
        fn cmp(k: *const StorePath, in: InputDrv) std.math.Order {
            return k.order(&in.path);
        }
    }.cmp) orelse return null;
    return inputs[i].node;
}

const Inputs = struct { pairs: []const Pair, added: []const StorePath, removed: []const StorePath };

/// The input derivations that are not on both sides, paired by derivation
/// name; the rest are added or removed.
fn pairInputs(gpa: Allocator, arena: Allocator, a: []const InputDrv, b: []const InputDrv) Allocator.Error!Inputs {
    var pairs: std.ArrayList(Pair) = .empty;
    // the same path on both sides, with different wanted outputs
    for (a) |in| if (lookup(b, &in.path)) |n| if (!nodeEql(in.node, n))
        try pairs.append(arena, .{ .a = in.path, .b = in.path });
    // each side's own paths, by name and then path: a stable sort keeps
    // the path order within a name, the order Rust iets reports
    const left = try only(gpa, a, b);
    defer gpa.free(left);
    const right = try only(gpa, b, a);
    defer gpa.free(right);
    var added: std.ArrayList(StorePath) = .empty;
    var removed: std.ArrayList(StorePath) = .empty;
    var i: usize = 0;
    var j: usize = 0;
    while (i < left.len or j < right.len) {
        const ord: std.math.Order = if (i == left.len) .gt else if (j == right.len) .lt else std.mem.order(u8, left[i].name(), right[j].name());
        const name = if (ord == .gt) right[j].name() else left[i].name();
        const xe = groupEnd(left, i, name);
        const ye = groupEnd(right, j, name);
        var k: usize = 0;
        while (i + k < xe or j + k < ye) : (k += 1) {
            if (i + k < xe and j + k < ye)
                try pairs.append(arena, .{ .a = left[i + k], .b = right[j + k] })
            else if (i + k < xe)
                try removed.append(arena, left[i + k])
            else
                try added.append(arena, right[j + k]);
        }
        i = xe;
        j = ye;
    }
    return .{ .pairs = pairs.items, .added = added.items, .removed = removed.items };
}

/// The end of the run of paths named `name` from `i`.
fn groupEnd(ps: []const StorePath, i: usize, name: []const u8) usize {
    var e = i;
    while (e < ps.len and std.mem.eql(u8, ps[e].name(), name)) e += 1;
    return e;
}

/// The paths of `x` that `y` has not got, ordered by name, then path.
fn only(gpa: Allocator, x: []const InputDrv, y: []const InputDrv) Allocator.Error![]StorePath {
    var out: std.ArrayList(StorePath) = .empty;
    errdefer out.deinit(gpa);
    for (x) |in| if (lookup(y, &in.path) == null) try out.append(gpa, in.path);
    std.mem.sort(StorePath, out.items, {}, struct {
        fn lt(_: void, p: StorePath, q: StorePath) bool {
            return std.mem.lessThan(u8, p.name(), q.name());
        }
    }.lt);
    return out.toOwnedSlice(gpa);
}

/// The next code point of `s` at `i.*`, or U+FFFD for an invalid sequence,
/// which it steps over as Rust iets's lossy conversion does.
fn nextLossy(s: []const u8, i: *usize) struct { c: u21, bytes: []const u8 } {
    const n = std.unicode.utf8ByteSequenceLength(s[i.*]) catch 0;
    if (n > 0 and i.* + n <= s.len) if (std.unicode.utf8Decode(s[i.* .. i.* + n])) |c| {
        defer i.* += n;
        return .{ .c = c, .bytes = s[i.* .. i.* + n] };
    } else |_| {};
    i.* += text.invalidLen(s, i.*);
    return .{ .c = 0xfffd, .bytes = "\u{fffd}" };
}

/// `s` lossy and quoted as Rust iets writes it (Rust's `{:?}`): `\"`, `\\`,
/// `\n`, `\r`, `\t`, `\0`, and `\u{..}` for the other control characters.
/// Rust also escapes a few non-printable code points beyond them; only
/// the C1 controls and the soft hyphen are handled here.
pub fn writeDebug(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    var i: usize = 0;
    while (i < s.len) {
        const x = nextLossy(s, &i);
        switch (x.c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0 => try w.writeAll("\\0"),
            1...8, 0x0b, 0x0c, 0x0e...0x1f, 0x7f...0x9f, 0xad => try w.print("\\u{{{x}}}", .{x.c}),
            else => try w.writeAll(x.bytes),
        }
    }
    try w.writeByte('"');
}

// Tests

const testing = std.testing;

/// The loader a test uses: the derivations it made, by path.
const Store = struct {
    arena: Allocator,
    drvs: std.ArrayList(struct { path: StorePath, drv: Derivation }) = .empty,

    fn add(s: *Store, drv: Derivation) !StorePath {
        var d: Diag = .init(testing.allocator);
        defer d.deinit();
        const p = try drv.drvPath(testing.allocator, &d);
        try s.drvs.append(s.arena, .{ .path = p, .drv = drv });
        return p;
    }

    fn loadFn(ctx: *anyopaque, _: Allocator, p: StorePath, d: *Diag) Error!Derivation {
        const s: *Store = @ptrCast(@alignCast(ctx));
        for (s.drvs.items) |e| if (e.path.eql(&p)) return e.drv;
        return d.fail(error.BadDerivation, "no {f}", .{&p});
    }

    fn diff_(s: *Store, a: StorePath, b: StorePath, depth: usize) !Diff {
        var d: Diag = .init(testing.allocator);
        defer d.deinit();
        return diff(testing.allocator, s.arena, .{ .ctx = s, .loadFn = loadFn }, a, b, depth, &d);
    }
};

const Kv = struct { []const u8, []const u8 };

fn mkDrv(arena: Allocator, name: []const u8, args_: []const []const u8, env_: []const Kv) !Derivation {
    var d: Derivation = .{ .name = name, .platform = "x86_64-linux", .builder = "/bin/sh", .args = args_ };
    d.outputs = try arena.dupe(drv_mod.NamedOutput, &.{.{ .name = "out", .output = .deferred }});
    for (env_) |kv| try d.envSet(arena, kv[0], kv[1]);
    return d;
}

/// The items of `d` as `what|key|a|b`, for a readable assertion.
fn expectItems(d: Diff, want: []const []const u8) !void {
    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |l| testing.allocator.free(l);
        lines.deinit(testing.allocator);
    }
    for (d.items) |i| try lines.append(testing.allocator, try std.fmt.allocPrint(testing.allocator, "{s}|{s}|{s}|{s}", .{ i.what, i.key, i.a orelse "-", i.b orelse "-" }));
    try testing.expectEqual(want.len, lines.items.len);
    for (want, lines.items) |x, y| try testing.expectEqualStrings(x, y);
}

fn outNode(arena: Allocator) !InputNode {
    return .{ .outputs = try arena.dupe([]const u8, &.{"out"}) };
}

fn withInput(arena: Allocator, drv: Derivation, p: StorePath) !Derivation {
    var t = drv;
    t.input_drvs = try arena.dupe(InputDrv, &.{.{ .path = p, .node = try outNode(arena) }});
    return t;
}

test "the same derivation is empty" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var s: Store = .{ .arena = arena.allocator() };
    const p = try s.add(try mkDrv(s.arena, "foo", &.{ "-c", "true" }, &.{.{ "x", "1" }}));
    const d = try s.diff_(p, p, 2);
    try testing.expect(d.isEmpty());
}

test "the local fields, the env and an absent value" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var s: Store = .{ .arena = arena.allocator() };
    const a = try s.add(try mkDrv(s.arena, "foo", &.{ "-c", "true" }, &.{ .{ "x", "1" }, .{ "gone", "" } }));
    var second = try mkDrv(s.arena, "foo", &.{ "-c", "false" }, &.{ .{ "x", "2" }, .{ "new", "" } });
    second.platform = "aarch64-linux";
    const b = try s.add(second);
    const d = try s.diff_(a, b, 2);
    try expectItems(d, &.{
        "platform||x86_64-linux|aarch64-linux",
        "args||\"-c\"\n\"true\"\n|\"-c\"\n\"false\"\n",
        "env|gone||-",
        "env|new|-|",
        "env|x|1|2",
    });
    try testing.expectEqual(0, d.changed.len);
}

// Nix sets `name` in the environment as well, so `env name` repeats the
// `name` item; it shows only when it says something else.
test "env name shows only when it is not the derivation name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var s: Store = .{ .arena = arena.allocator() };
    var a = try s.add(try mkDrv(s.arena, "ux-one", &.{}, &.{.{ "name", "ux-one" }}));
    var b = try s.add(try mkDrv(s.arena, "ux-two", &.{}, &.{.{ "name", "ux-two" }}));
    try expectItems(try s.diff_(a, b, 2), &.{"name||ux-one|ux-two"});

    a = try s.add(try mkDrv(s.arena, "ux-one", &.{}, &.{.{ "name", "other" }}));
    b = try s.add(try mkDrv(s.arena, "ux-two", &.{}, &.{.{ "name", "ux-two" }}));
    try expectItems(try s.diff_(a, b, 2), &.{ "name||ux-one|ux-two", "env|name|other|ux-two" });

    a = try s.add(try mkDrv(s.arena, "ux-one", &.{}, &.{.{ "name", "ux-one" }}));
    b = try s.add(try mkDrv(s.arena, "ux-two", &.{}, &.{}));
    try expectItems(try s.diff_(a, b, 2), &.{ "name||ux-one|ux-two", "env|name|ux-one|-" });
}

test "a changed input drv is paired by name and recursed into" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var s: Store = .{ .arena = arena.allocator() };
    const pa = try s.add(try mkDrv(s.arena, "dep", &.{ "-c", "a" }, &.{}));
    const pb = try s.add(try mkDrv(s.arena, "dep", &.{ "-c", "b" }, &.{}));
    const x = try s.add(try withInput(s.arena, try mkDrv(s.arena, "top", &.{}, &.{}), pa));
    const y = try s.add(try withInput(s.arena, try mkDrv(s.arena, "top", &.{}, &.{}), pb));
    const d = try s.diff_(x, y, 2);
    // paired, not added or removed
    try testing.expectEqual(0, d.items.len);
    try testing.expectEqual(1, d.changed.len);
    try expectItems(d.changed[0], &.{"args||\"-c\"\n\"a\"\n|\"-c\"\n\"b\"\n"});
}

test "the depth limit names the input without walking it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var s: Store = .{ .arena = arena.allocator() };
    const x = try s.add(try withInput(s.arena, try mkDrv(s.arena, "top", &.{}, &.{}), try s.add(try mkDrv(s.arena, "dep", &.{"a"}, &.{}))));
    const y = try s.add(try withInput(s.arena, try mkDrv(s.arena, "top", &.{}, &.{}), try s.add(try mkDrv(s.arena, "dep", &.{"b"}, &.{}))));
    const d = try s.diff_(x, y, 0);
    try testing.expectEqual(1, d.changed.len);
    try testing.expectEqualStrings("depth", d.changed[0].cut.?);
    try testing.expectEqual(0, d.changed[0].items.len);
}

test "an input source, an added input drv and a fixed output show up" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var s: Store = .{ .arena = arena.allocator() };
    const dep = try s.add(try mkDrv(s.arena, "dep", &.{}, &.{}));
    var a = try mkDrv(s.arena, "top", &.{}, &.{});
    var b = try mkDrv(s.arena, "top", &.{}, &.{});
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    a.input_srcs = try s.arena.dupe(StorePath, &.{try StorePath.fromBaseName("00000000000000000000000000000000-a.txt", &d)});
    b.input_srcs = try s.arena.dupe(StorePath, &.{try StorePath.fromBaseName("11111111111111111111111111111111-b.txt", &d)});
    b = try withInput(s.arena, b, dep);
    a.outputs = try s.arena.dupe(drv_mod.NamedOutput, &.{.{ .name = "out", .output = .{ .fixed = .{ .method = .flat, .hash = hash_mod.hashBytes(.sha256, "one") } } }});
    b.outputs = try s.arena.dupe(drv_mod.NamedOutput, &.{.{ .name = "out", .output = .{ .fixed = .{ .method = .flat, .hash = hash_mod.hashBytes(.sha256, "two") } } }});
    const x = try s.add(a);
    const y = try s.add(b);
    const r = try s.diff_(x, y, 2);
    const kinds = [_][]const u8{ "output", "input source", "input source", "input drv" };
    try testing.expectEqual(kinds.len, r.items.len);
    for (kinds, r.items) |k, i| try testing.expectEqualStrings(k, i.what);
    try testing.expectEqualStrings("out", r.items[0].key);
    try testing.expect(r.items[1].b == null and r.items[2].a == null);
    // the input drv is added
    try testing.expect(r.items[3].a == null);
}

test "a pair met twice is shown once" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var s: Store = .{ .arena = arena.allocator() };
    const pa = try s.add(try mkDrv(s.arena, "dep", &.{"a"}, &.{}));
    const pb = try s.add(try mkDrv(s.arena, "dep", &.{"b"}, &.{}));
    const ma = try s.add(try withInput(s.arena, try mkDrv(s.arena, "mid", &.{}, &.{}), pa));
    const mb = try s.add(try withInput(s.arena, try mkDrv(s.arena, "mid", &.{}, &.{}), pb));
    var ta = try mkDrv(s.arena, "top", &.{}, &.{});
    var tb = try mkDrv(s.arena, "top", &.{}, &.{});
    const on = try outNode(s.arena);
    var ins_a = [_]InputDrv{ .{ .path = pa, .node = on }, .{ .path = ma, .node = on } };
    var ins_b = [_]InputDrv{ .{ .path = pb, .node = on }, .{ .path = mb, .node = on } };
    std.mem.sort(InputDrv, &ins_a, {}, inputLess);
    std.mem.sort(InputDrv, &ins_b, {}, inputLess);
    ta.input_drvs = &ins_a;
    tb.input_drvs = &ins_b;
    const d = try s.diff_(try s.add(ta), try s.add(tb), all_levels);
    try testing.expectEqual(2, d.changed.len);
    var cuts: usize = 0;
    for (d.changed) |c| {
        if (c.changed.len == 1) cuts += @intFromBool(c.changed[0].cut != null);
    }
    try testing.expectEqual(1, cuts);
}

fn inputLess(_: void, x: InputDrv, y: InputDrv) bool {
    return x.path.order(&y.path) == .lt;
}

test "args are quoted as Rust's Debug quotes them" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeDebug(&out.writer, "a\"b\\c\n\x00\x1b'é\xff");
    try testing.expectEqualStrings("\"a\\\"b\\\\c\\n\\0\\u{1b}'é\u{fffd}\"", out.written());
}
