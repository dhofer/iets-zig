//! `--constituents`: constituents.cc. After the walk, every
//! `_hydraAggregate` job with named constituents is resolved against the
//! job table, its `.drv` rewritten with the constituents as `inputDrvs`
//! (output paths recomputed, written through the daemon, rooted) and
//! printed; a missing or failed constituent makes the aggregate an error
//! line that keeps its job fields.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Diag = @import("../diag.zig").Diag;
const Scratch = @import("../Scratch.zig");
const Log = @import("../log.zig").Log;
const Error = @import("../jobs.zig").Error;
const line_mod = @import("line.zig");
const Job = line_mod.Job;
const Line = line_mod.Line;
const plan = @import("../remote/plan.zig");
const worker = @import("../remote/worker.zig");
const Connection = worker.Connection;
const wire = worker.wire;
const drv_mod = @import("../store/drv.zig");
const path_mod = @import("../store/path.zig");
const StorePath = path_mod.StorePath;

/// What the collector keeps of every line: enough to resolve names.
pub const Entry = struct {
    drv_path: ?StorePath = null,
    /// The `error` field of an error line, owned.
    message: ?[]const u8 = null,
    /// An aggregate with named constituents, withheld until `rewrite`.
    held: ?Job = null,

    pub fn deinit(e: *Entry, gpa: Allocator) void {
        if (e.message) |m| gpa.free(m);
        if (e.held) |*j| j.deinit(gpa);
        e.* = undefined;
    }
};

/// Every line by attribute name. A hash map: the walk inserts one entry per
/// line, and only `rewrite` needs the names in order, sorted once there.
pub const Jobs = struct {
    map: std.StringHashMapUnmanaged(Entry) = .empty,

    pub fn deinit(j: *Jobs, gpa: Allocator) void {
        var it = j.map.iterator();
        while (it.next()) |kv| {
            gpa.free(kv.key_ptr.*);
            kv.value_ptr.deinit(gpa);
        }
        j.map.deinit(gpa);
    }

    /// Takes `entry` (freed on failure); a later line for the same name
    /// replaces the earlier one.
    pub fn put(j: *Jobs, gpa: Allocator, attr: []const u8, entry: Entry) Allocator.Error!void {
        var e = entry;
        errdefer e.deinit(gpa);
        const gop = try j.map.getOrPut(gpa, attr);
        if (gop.found_existing) {
            gop.value_ptr.deinit(gpa);
        } else {
            gop.key_ptr.* = gpa.dupe(u8, attr) catch |err| {
                j.map.removeByPtr(gop.key_ptr);
                return err;
            };
        }
        gop.value_ptr.* = e;
    }

    pub fn getPtr(j: *const Jobs, name: []const u8) ?*Entry {
        return j.map.getPtr(name);
    }

    /// Every name, bytewise sorted: the order Rust iets resolves them in.
    fn sortedNames(j: *const Jobs, arena: Allocator) Allocator.Error![]const []const u8 {
        const names = try arena.alloc([]const u8, j.map.count());
        var it = j.map.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| : (i += 1) names[i] = k.*;
        std.mem.sortUnstable([]const u8, names, {}, strLess);
        return names;
    }
};

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// A constituent that cannot go in, and why.
const Broken = struct { name: []const u8, err: []const u8 };

const Aggregate = struct {
    name: []const u8,
    /// Sorted, unique.
    dependencies: []const []const u8,
    /// Sorted by name, unique.
    broken: []const Broken,
};

const Cycle = struct {
    a: []const u8,
    b: []const u8,
    /// Sorted.
    remaining: []const []const u8,
};

/// fnmatch(3) with no flags: `*`, `?`, `[...]` (with `!`/`^` and ranges),
/// `\` escapes; `/` and a leading `.` are not special.
pub fn fnmatch(pattern: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    var star: ?struct { p: usize, n: usize } = null;
    while (n < name.len) {
        if (p < pattern.len) step: {
            switch (pattern[p]) {
                '*' => {
                    star = .{ .p = p, .n = n };
                    p += 1;
                    continue;
                },
                '?' => {
                    p += 1;
                    n += 1;
                    continue;
                },
                '[' => {
                    if (bracket(pattern[p + 1 ..], name[n])) |b| {
                        if (b.matched) {
                            p += 1 + b.used;
                            n += 1;
                            continue;
                        }
                    } else if (name[n] == '[') {
                        p += 1;
                        n += 1;
                        continue;
                    }
                    break :step;
                },
                '\\' => if (p + 1 < pattern.len) {
                    if (pattern[p + 1] == name[n]) {
                        p += 2;
                        n += 1;
                        continue;
                    }
                    break :step;
                },
                else => {},
            }
            if (pattern[p] == name[n]) {
                p += 1;
                n += 1;
                continue;
            }
        }
        const s = star orelse return false;
        p = s.p + 1;
        n = s.n + 1;
        star = .{ .p = s.p, .n = s.n + 1 };
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

/// `p` starts after '['; whether `c` matched and the bytes the bracket
/// took, `]` included. `null` when it never closes.
fn bracket(p: []const u8, c: u8) ?struct { matched: bool, used: usize } {
    var i: usize = 0;
    const negate = p.len > 0 and (p[0] == '!' or p[0] == '^');
    if (negate) i = 1;
    var matched = false;
    var first = true;
    while (true) {
        if (i >= p.len) return null;
        const b = p[i];
        if (b == ']' and !first) return .{ .matched = matched != negate, .used = i + 1 };
        first = false;
        var lo = b;
        if (b == '\\') {
            i += 1;
            if (i >= p.len) return null;
            lo = p[i];
        }
        i += 1;
        if (i + 1 < p.len and p[i] == '-' and p[i + 1] != ']') {
            var hi = p[i + 1];
            i += 2;
            if (hi == '\\') {
                if (i >= p.len) return null;
                hi = p[i];
                i += 1;
            }
            if (lo <= c and c <= hi) matched = true;
        } else if (lo == c) matched = true;
    }
}

fn say(log: ?*Log, arena: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    const l = log orelse return;
    l.textLine(try std.fmt.allocPrint(arena, fmt, args));
}

/// constituents.cc:resolveNamedConstituents: which jobs each aggregate
/// depends on and which of its constituents are broken. `names` are the
/// keys of `jobs`, sorted.
fn resolveNamed(arena: Allocator, jobs: *const Jobs, names: []const []const u8, log: ?*Log) Allocator.Error![]Aggregate {
    var aggregates: std.ArrayList(Aggregate) = .empty;
    for (names) |name| {
        const job = if (jobs.getPtr(name).?.held) |*j| j else continue;
        const named = job.named_constituents orelse continue;
        if (named.len == 0) continue;
        var broken: std.ArrayList(Broken) = .empty;
        var results: std.ArrayList([]const u8) = .empty;
        for (named) |named_child| {
            // the job frees its names once resolved, before the error text
            // is made of them
            const child = try arena.dupe(u8, named_child);
            if (jobs.getPtr(child)) |e| {
                if (e.message) |err| {
                    try say(log, arena, "error: aggregate job '{s}' references broken job '{s}': {s}", .{ name, child, err });
                    try broken.append(arena, .{ .name = child, .err = err });
                } else try results.append(arena, child);
            } else if (!job.glob_constituents) {
                try say(log, arena, "error: aggregate job '{s}' references non-existent job '{s}'", .{ name, child });
                try broken.append(arena, .{ .name = child, .err = "does not exist" });
            } else {
                var found = false;
                for (names) |other| {
                    if (std.mem.eql(u8, other, name) or !fnmatch(child, other)) continue;
                    if (jobs.getPtr(other).?.message) |err| {
                        try say(log, arena, "error: aggregate job '{s}' references broken job '{s}': {s}", .{ name, other, err });
                        try broken.append(arena, .{ .name = other, .err = err });
                        continue;
                    }
                    try results.append(arena, other);
                    found = true;
                }
                if (!found) {
                    try say(log, arena, "warning: aggregate job '{s}' references constituent glob pattern '{s}' with no matches", .{ name, child });
                    try broken.append(arena, .{ .name = child, .err = "constituent glob pattern had no matches" });
                }
            }
        }
        // a set and a map: sorted, and the last insert of a name wins
        std.mem.sortUnstable([]const u8, results.items, {}, strLess);
        var n: usize = 0;
        for (results.items) |r| {
            if (n > 0 and std.mem.eql(u8, results.items[n - 1], r)) continue;
            results.items[n] = r;
            n += 1;
        }
        std.mem.sort(Broken, broken.items, {}, struct {
            fn lt(_: void, a: Broken, b: Broken) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lt);
        var m: usize = 0;
        for (broken.items, 0..) |b, i| {
            if (i + 1 < broken.items.len and std.mem.eql(u8, b.name, broken.items[i + 1].name)) continue;
            broken.items[m] = b;
            m += 1;
        }
        try aggregates.append(arena, .{ .name = name, .dependencies = results.items[0..n], .broken = broken.items[0..m] });
    }
    return aggregates.items;
}

const Sorted = union(enum) {
    /// Indices into the aggregates, dependencies first.
    order: []const u32,
    cycle: Cycle,
};

/// constituents.cc:topoSort: dependencies first; a cycle names the two
/// jobs and every aggregate not yet erased. `aggs` are sorted by name.
fn topoSort(arena: Allocator, aggs: []const Aggregate) Allocator.Error!Sorted {
    const T = struct {
        aggs: []const Aggregate,
        visited: []bool,
        parents: []bool,
        sorted: std.ArrayList(u32),
        cycle: ?[2]u32 = null,

        fn index(t: *const @This(), name: []const u8) ?u32 {
            const i = std.sort.binarySearch(Aggregate, t.aggs, name, struct {
                fn cmp(k: []const u8, a: Aggregate) std.math.Order {
                    return std.mem.order(u8, k, a.name);
                }
            }.cmp) orelse return null;
            return @intCast(i);
        }

        /// `false` once a cycle is found, in `cycle`.
        fn visit(t: *@This(), i: u32, parent: u32) bool {
            if (t.parents[i]) {
                t.cycle = .{ i, parent };
                return false;
            }
            if (t.visited[i]) return true;
            t.visited[i] = true;
            t.parents[i] = true;
            for (t.aggs[i].dependencies) |r| {
                const j = t.index(r) orelse continue;
                if (j != i and !t.visit(j, i)) return false;
            }
            t.sorted.appendAssumeCapacity(i);
            t.parents[i] = false;
            return true;
        }
    };
    var t: T = .{
        .aggs = aggs,
        .visited = try arena.alloc(bool, aggs.len),
        .parents = try arena.alloc(bool, aggs.len),
        .sorted = try .initCapacity(arena, aggs.len),
    };
    @memset(t.visited, false);
    @memset(t.parents, false);
    for (0..aggs.len) |i| {
        // a root is never on the path, so its parent is never read
        if (t.visit(@intCast(i), 0)) continue;
        const c = t.cycle.?;
        var remaining: std.ArrayList([]const u8) = try .initCapacity(arena, aggs.len);
        for (aggs, 0..) |a, k| if (k != c[0] and k != c[1]) remaining.appendAssumeCapacity(a.name);
        return .{ .cycle = .{ .a = aggs[c[0]].name, .b = aggs[c[1]].name, .remaining = remaining.items } };
    }
    return .{ .order = t.sorted.items };
}

/// Where `rewrite` sends each aggregate it resolved; the line is the
/// callee's only for the call.
pub const Out = struct {
    ctx: ?*anyopaque,
    f: *const fn (ctx: ?*anyopaque, line: *const Line) void,
};

fn setError(gpa: Allocator, job: *Job, msg: []const u8) Allocator.Error!void {
    try job.putExtra(gpa, "error", try line_mod.jsonStr(gpa, msg));
}

fn send(gpa: Allocator, out: Out, job: Job) void {
    var l: Line = .{ .job = job };
    out.f(out.ctx, &l);
    l.deinit(gpa);
}

fn take(jobs: *Jobs, name: []const u8) ?Job {
    const e = jobs.getPtr(name) orelse return null;
    const j = e.held orelse return null;
    e.held = null;
    return j;
}

/// A derivation error is a store error; its message is in the `Diag`.
fn storeErr(e: drv_mod.Error) Error {
    return if (e == error.OutOfMemory) error.OutOfMemory else error.Store;
}

/// `AddMultipleToStore` of one object.
fn addObject(gpa: Allocator, io: Io, conn: *Connection, object: *const plan.Object, d: *Diag) Error!void {
    var up = try conn.addMultipleToStore(false, d);
    const w = up.writer();
    wire.writeU64(w, 1) catch |e| return up.fail(e, d);
    wire.writeObject(gpa, io, w, object, d) catch |e| return up.fail(e, d);
    try up.finish(.ignore, d);
}

/// Resolves and prints every withheld aggregate through `out`. Messages
/// go to `log` (dropped when null).
pub fn rewrite(
    gpa: Allocator,
    io: Io,
    jobs: *Jobs,
    conn: *Connection,
    log: ?*Log,
    gc_roots_dir: ?[]const u8,
    out: Out,
    d: *Diag,
) Error!void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const names = try jobs.sortedNames(arena);
    const aggregates = try resolveNamed(arena, jobs, names, log);
    const order = switch (try topoSort(arena, aggregates)) {
        .order => |o| o,
        .cycle => |c| {
            const msg = try std.fmt.allocPrint(arena, "Dependency cycle: {s} <-> {s}", .{ c.a, c.b });
            try say(log, arena, "error: Found dependency cycle between jobs '{s}' and '{s}'", .{ c.a, c.b });
            for ([_][]const u8{ c.a, c.b }) |name| try sendError(gpa, jobs, name, msg, out);
            for (c.remaining) |name| try sendError(gpa, jobs, name, "Skipping aggregate because of a dependency cycle", out);
            return;
        },
    };
    var hash_cache: drv_mod.DrvHashCache = .init(gpa);
    defer hash_cache.deinit();
    var store_loader: drv_mod.StoreLoader = .{ .io = io };
    var tmp: Scratch = .init(gpa);
    defer tmp.deinit();
    for (order) |ai| {
        const agg = &aggregates[ai];
        var job = take(jobs, agg.name) orelse continue;
        errdefer job.deinit(gpa);
        tmp.reset();
        if (agg.broken.len == 0) {
            try resolveOne(gpa, io, tmp.allocator(), jobs, agg, &job, conn, &hash_cache, store_loader.loader(), gc_roots_dir, d);
        }
        job.setNamedConstituents(gpa, null);
        if (agg.broken.len > 0) {
            var msg: std.ArrayList(u8) = .empty;
            for (agg.broken) |b| {
                try msg.appendSlice(arena, b.name);
                try msg.appendSlice(arena, ": ");
                try msg.appendSlice(arena, b.err);
                try msg.append(arena, '\n');
            }
            try setError(gpa, &job, msg.items);
        }
        send(gpa, out, job);
    }
}

fn sendError(gpa: Allocator, jobs: *Jobs, name: []const u8, msg: []const u8, out: Out) Allocator.Error!void {
    var job = take(jobs, name) orelse return;
    errdefer job.deinit(gpa);
    try setError(gpa, &job, msg);
    send(gpa, out, job);
}

/// One aggregate whose constituents all resolved: its `.drv` with them as
/// inputs, registered and rooted when that changed its path. `a` holds
/// the derivations for this aggregate only.
fn resolveOne(
    gpa: Allocator,
    io: Io,
    a: Allocator,
    jobs: *Jobs,
    agg: *const Aggregate,
    job: *Job,
    conn: *Connection,
    hash_cache: *drv_mod.DrvHashCache,
    loader: drv_mod.Loader,
    gc_roots_dir: ?[]const u8,
    d: *Diag,
) Error!void {
    var drv = drv_mod.loadDerivationFromStore(io, a, job.drv_path, d) catch |e| return storeErr(e);
    var inputs: std.ArrayList(drv_mod.InputDrv) = try .initCapacity(a, drv.input_drvs.len + agg.dependencies.len);
    inputs.appendSliceAssumeCapacity(drv.input_drvs);
    try job.constituents.ensureUnusedCapacity(gpa, agg.dependencies.len);
    for (agg.dependencies) |dep| {
        const child = jobs.getPtr(dep).?.drv_path orelse
            return d.fail(error.Store, "constituent '{s}' has no drvPath", .{dep});
        const child_drv = drv_mod.loadDerivationFromStore(io, a, child, d) catch |e| return storeErr(e);
        if (child_drv.outputs.len == 0) return d.fail(error.Store, "derivation '{f}' has no outputs", .{&child});
        const first = try a.alloc([]const u8, 1);
        first[0] = child_drv.outputs[0].name;
        job.constituents.appendAssumeCapacity(child);
        const node: drv_mod.InputNode = .{ .outputs = first };
        // a map insert: a constituent that already is an input gets this node
        var lo: usize = 0;
        var hi: usize = inputs.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (inputs.items[mid].path.order(&child) == .lt) lo = mid + 1 else hi = mid;
        }
        if (lo < inputs.items.len and inputs.items[lo].path.eql(&child)) {
            inputs.items[lo].node = node;
        } else inputs.insertAssumeCapacity(lo, .{ .path = child, .node = node });
    }
    drv.input_drvs = inputs.items;
    // Deferred outputs make fillInOutputPaths recompute them with the new
    // inputDrvs.
    for (drv.outputs) |*o| if (o.output == .input_addressed) {
        o.output = .deferred;
        try drv.envSet(a, o.name, "");
    };
    drv_mod.finalizeInputAddressedOutputs(a, &drv, hash_cache, loader, d) catch |e| return storeErr(e);
    const aterm = drv.unparseAlloc(a, .{}, d) catch |e| return storeErr(e);
    const new_path = drv.drvPathFor(a, aterm, d) catch |e| return storeErr(e);
    if (new_path.eql(&job.drv_path)) return;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const full = new_path.print(&buf);
    const valid = try conn.queryValid(a, &.{new_path}, .ignore, d);
    if (valid.len == 0) {
        const refs = try a.alloc(StorePath, drv.input_srcs.len + drv.input_drvs.len);
        @memcpy(refs[0..drv.input_srcs.len], drv.input_srcs);
        for (drv.input_drvs, refs[drv.input_srcs.len..]) |in, *r| r.* = in.path;
        const object = plan.Object.drvObject(new_path, aterm, path_mod.sortUnique(refs));
        try addObject(gpa, io, conn, &object, d);
    }
    if (gc_roots_dir) |dir| {
        const root = try std.fs.path.join(a, &.{ dir, new_path.baseName() });
        if (Io.Dir.cwd().statFile(io, root, .{ .follow_symlinks = false })) |_| {} else |_| {
            try conn.addPermRoot(full, root, d);
        }
    }
    job.drv_path = new_path;
    var pd: Diag = .init(gpa);
    defer pd.deinit();
    for (drv.outputs) |o| {
        const p = if (drv.envGet(o.name)) |s| StorePath.parse(s, &pd) catch null else null;
        try job.putOutput(gpa, o.name, p);
    }
    jobs.getPtr(agg.name).?.drv_path = new_path;
}

const testing = std.testing;

test "fnmatch basics" {
    const cases = [_]struct { []const u8, []const u8, bool }{
        .{ "*", "anything.here", true },
        .{ "packages.*", "packages.constituentA", true },
        .{ "tests.*", "packages.constituentA", false },
        .{ "a?c", "abc", true },
        .{ "a?c", "abbc", false },
        .{ "a[b-d]c", "acc", true },
        .{ "a[!b-d]c", "acc", false },
        .{ "a\\*c", "a*c", true },
        .{ "a\\*c", "abc", false },
        .{ "*.x86_64-linux", "nixos.tests.login.x86_64-linux", true },
        .{ "abc", "abcd", false },
        .{ "a*b*c", "axxbyyc", true },
        // an unclosed bracket is literal, `^` negates
        .{ "a[b", "a[b", true },
        .{ "a[^x]c", "abc", true },
        .{ "a[]]c", "a]c", true },
    };
    for (cases) |c| testing.expectEqual(c[2], fnmatch(c[0], c[1])) catch |e| {
        std.debug.print("fnmatch({s}, {s})\n", .{ c[0], c[1] });
        return e;
    };
}

test "topoSort orders and detects cycles" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ok = [_]Aggregate{
        .{ .name = "direct", .dependencies = &.{"leaf"}, .broken = &.{} },
        .{ .name = "indirect", .dependencies = &.{"direct"}, .broken = &.{} },
    };
    const sorted = try topoSort(a, &ok);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, sorted.order);

    const cyclic = [_]Aggregate{
        .{ .name = "aggregate0", .dependencies = &.{"aggregate1"}, .broken = &.{} },
        .{ .name = "aggregate1", .dependencies = &.{"aggregate0"}, .broken = &.{} },
        .{ .name = "other", .dependencies = &.{}, .broken = &.{} },
    };
    const c = (try topoSort(a, &cyclic)).cycle;
    try testing.expectEqualStrings("aggregate0", c.a);
    try testing.expectEqualStrings("aggregate1", c.b);
    try testing.expectEqual(1, c.remaining.len);
    try testing.expectEqualStrings("other", c.remaining[0]);
}

fn testJob(gpa: Allocator, attr: []const u8, named: ?[]const []const u8, glob: bool) !Job {
    var d: Diag = .init(gpa);
    defer d.deinit();
    const path = try gpa.alloc([]const u8, 1);
    path[0] = try gpa.dupe(u8, attr);
    var j: Job = .{
        .attr = try gpa.dupe(u8, attr),
        .attr_path = path,
        .drv_path = try StorePath.parse("/nix/store/00000000000000000000000000000000-x.drv", &d),
        .glob_constituents = glob,
    };
    if (named) |n| {
        const copy = try gpa.alloc([]const u8, n.len);
        for (n, copy) |s, *c| c.* = try gpa.dupe(u8, s);
        j.named_constituents = copy;
    }
    return j;
}

test "named constituents resolve to jobs, globs and broken ones" {
    const gpa = testing.allocator;
    var jobs: Jobs = .{};
    defer jobs.deinit(gpa);
    try jobs.put(gpa, "packages.a", .{});
    try jobs.put(gpa, "packages.b", .{});
    try jobs.put(gpa, "failed", .{ .message = try gpa.dupe(u8, "boom") });
    try jobs.put(gpa, "agg", .{ .held = try testJob(gpa, "agg", &.{ "packages.b", "failed", "missing" }, false) });
    try jobs.put(gpa, "glob", .{ .held = try testJob(gpa, "glob", &.{ "packages.*", "nothing.*" }, true) });
    // a later line for a name replaces the earlier one
    try jobs.put(gpa, "packages.a", .{});

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const names = try jobs.sortedNames(a);
    try testing.expectEqual(5, names.len);
    const aggs = try resolveNamed(a, &jobs, names, null);
    try testing.expectEqual(2, aggs.len);
    try testing.expectEqualStrings("agg", aggs[0].name);
    try testing.expectEqual(1, aggs[0].dependencies.len);
    try testing.expectEqualStrings("packages.b", aggs[0].dependencies[0]);
    try testing.expectEqual(2, aggs[0].broken.len);
    try testing.expectEqualStrings("failed", aggs[0].broken[0].name);
    try testing.expectEqualStrings("boom", aggs[0].broken[0].err);
    try testing.expectEqualStrings("missing", aggs[0].broken[1].name);
    try testing.expectEqualStrings("does not exist", aggs[0].broken[1].err);
    try testing.expectEqualStrings("glob", aggs[1].name);
    try testing.expectEqual(2, aggs[1].dependencies.len);
    try testing.expectEqualStrings("packages.a", aggs[1].dependencies[0]);
    try testing.expectEqual(1, aggs[1].broken.len);
    try testing.expectEqualStrings("constituent glob pattern had no matches", aggs[1].broken[0].err);
}

test "a dependency cycle prints both aggregates and skips the rest" {
    const gpa = testing.allocator;
    var jobs: Jobs = .{};
    defer jobs.deinit(gpa);
    try jobs.put(gpa, "aggregate0", .{ .held = try testJob(gpa, "aggregate0", &.{"aggregate1"}, false) });
    try jobs.put(gpa, "aggregate1", .{ .held = try testJob(gpa, "aggregate1", &.{"aggregate0"}, false) });
    try jobs.put(gpa, "other", .{ .held = try testJob(gpa, "other", &.{"aggregate0"}, false) });
    const Collect = struct {
        out: std.Io.Writer.Allocating,
        fn f(ctx: ?*anyopaque, l: *const Line) void {
            const c: *@This() = @ptrCast(@alignCast(ctx.?));
            l.render(&c.out.writer) catch unreachable;
            c.out.writer.writeByte('\n') catch unreachable;
        }
    };
    var c: Collect = .{ .out = .init(gpa) };
    defer c.out.deinit();
    var d: Diag = .init(gpa);
    defer d.deinit();
    // the cycle is found before anything needs the connection
    try rewrite(gpa, testing.io, &jobs, undefined, null, null, .{ .ctx = &c, .f = Collect.f }, &d);
    const want =
        \\{"attr":"aggregate0","attrPath":["aggregate0"],"constituents":[],"drvPath":"/nix/store/00000000000000000000000000000000-x.drv","error":"Dependency cycle: aggregate0 <-> aggregate1","globConstituents":false,"namedConstituents":["aggregate1"],"outputs":{}}
        \\{"attr":"aggregate1","attrPath":["aggregate1"],"constituents":[],"drvPath":"/nix/store/00000000000000000000000000000000-x.drv","error":"Dependency cycle: aggregate0 <-> aggregate1","globConstituents":false,"namedConstituents":["aggregate0"],"outputs":{}}
        \\{"attr":"other","attrPath":["other"],"constituents":[],"drvPath":"/nix/store/00000000000000000000000000000000-x.drv","error":"Skipping aggregate because of a dependency cycle","globConstituents":false,"namedConstituents":["aggregate0"],"outputs":{}}
        \\
    ;
    try testing.expectEqualStrings(want, c.out.written());
}

const socket = "/nix/var/nix/daemon-socket/socket";

/// A two-line `.drv` named `name` with `inputs`, its out path filled in,
/// registered through `conn` when `upload` is set.
fn testDrv(a: Allocator, conn: *Connection, name: []const u8, inputs: []const drv_mod.InputDrv, upload: bool, d: *Diag) !StorePath {
    const outs = try a.alloc(drv_mod.NamedOutput, 1);
    outs[0] = .{ .name = "out", .output = .deferred };
    var drv: drv_mod.Derivation = .{
        .name = name,
        .outputs = outs,
        .input_drvs = inputs,
        .platform = "x86_64-linux",
        .builder = "/bin/sh",
        .args = &.{ "-c", "echo > $out" },
    };
    for ([_][2][]const u8{ .{ "builder", "/bin/sh" }, .{ "name", name }, .{ "out", "" }, .{ "system", "x86_64-linux" } }) |kv|
        try drv.envSet(a, kv[0], kv[1]);
    var hash_cache: drv_mod.DrvHashCache = .init(testing.allocator);
    defer hash_cache.deinit();
    var sl: drv_mod.StoreLoader = .{ .io = testing.io };
    try drv_mod.finalizeInputAddressedOutputs(a, &drv, &hash_cache, sl.loader(), d);
    const aterm = try drv.unparseAlloc(a, .{}, d);
    const p = try drv.drvPathFor(a, aterm, d);
    if (upload) {
        const refs = try a.alloc(StorePath, inputs.len);
        for (inputs, refs) |in, *r| r.* = in.path;
        const object = plan.Object.drvObject(p, aterm, path_mod.sortUnique(refs));
        try addObject(testing.allocator, testing.io, conn, &object, d);
    }
    return p;
}

test "an aggregate is rewritten with its constituents, registered and rooted" {
    const gpa = testing.allocator;
    const io = testing.io;
    Io.Dir.cwd().access(io, socket, .{}) catch return error.SkipZigTest;
    var d: Diag = .init(gpa);
    defer d.deinit();
    errdefer std.debug.print("{s}\n", .{d.message()});
    const t: worker.Transport = .{ .unix = socket };
    const conn = try Connection.open(gpa, io, &t, null, .none, .ignore, &d);
    defer conn.close();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const c = try testDrv(a, conn, "iets-test-constituent", &.{}, true, &d);
    const agg_path = try testDrv(a, conn, "iets-test-aggregate", &.{}, true, &d);
    const want = try testDrv(a, conn, "iets-test-aggregate", &.{.{ .path = c, .node = .{ .outputs = &.{"out"} } }}, false, &d);

    var jobs: Jobs = .{};
    defer jobs.deinit(gpa);
    try jobs.put(gpa, "c", .{ .drv_path = c });
    var job = try testJob(gpa, "agg", &.{"c"}, false);
    job.drv_path = agg_path;
    try jobs.put(gpa, "agg", .{ .drv_path = agg_path, .held = job });

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const roots = pbuf[0..try tmp.dir.realPath(io, &pbuf)];
    const Collect = struct {
        got: ?Job = null,
        fn f(ctx: ?*anyopaque, l: *const Line) void {
            const s: *@This() = @ptrCast(@alignCast(ctx.?));
            const j = l.job;
            var copy: Job = .{ .attr = &.{}, .attr_path = &.{}, .drv_path = j.drv_path };
            copy.constituents.appendSlice(testing.allocator, j.constituents.items) catch unreachable;
            for (j.outputs.items) |o| copy.putOutput(testing.allocator, o.name, o.path) catch unreachable;
            if (j.getExtra("error") != null or j.named_constituents != null) unreachable;
            s.got = copy;
        }
    };
    var col: Collect = .{};
    defer if (col.got) |*g| g.deinit(gpa);
    try rewrite(gpa, io, &jobs, conn, null, roots, .{ .ctx = &col, .f = Collect.f }, &d);
    const got = col.got.?;
    try testing.expectEqualStrings(want.baseName(), got.drv_path.baseName());
    try testing.expectEqual(1, got.constituents.items.len);
    try testing.expectEqualStrings(c.baseName(), got.constituents.items[0].baseName());
    try testing.expectEqualStrings(want.baseName(), jobs.getPtr("agg").?.drv_path.?.baseName());

    // the new .drv is in the store, its out path the job's, and rooted
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const full = want.print(&buf);
    try testing.expectEqual(1, (try conn.queryValid(a, &.{want}, .ignore, &d)).len);
    const drv = try drv_mod.loadDerivationFromStore(io, a, want, &d);
    try testing.expectEqualStrings(drv.envGet("out").?, try std.fmt.allocPrint(a, "{f}", .{&got.outputs.items[0].path.?}));
    var lbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.readLink(io, want.baseName(), &lbuf);
    try testing.expectEqualStrings(full, lbuf[0..n]);
}
