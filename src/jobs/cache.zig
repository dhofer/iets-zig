//! `--check-cache-status`: cache-status-resolver.cc. A job is `local` when
//! every output is valid, `cached` when the missing outputs are all
//! substitutable, else `notBuilt` with the input drvs that will build
//! (post-order) and the outputs a substituter has. Validity and
//! substituter probes are batched: one `QueryValidPaths` and one
//! `QuerySubstitutablePathInfos` round trip per pass over the pending jobs.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Diag = @import("../diag.zig").Diag;
const Scratch = @import("../Scratch.zig");
const Error = @import("../jobs.zig").Error;
const line_mod = @import("line.zig");
const Job = line_mod.Job;
const Line = line_mod.Line;
const plan = @import("../remote/plan.zig");
const PathMap = plan.PathMap;
const PathSet = plan.PathSet;
const remote = @import("../remote.zig");
const worker = @import("../remote/worker.zig");
const Connection = worker.Connection;
const drv_mod = @import("../store/drv.zig");
const Derivation = drv_mod.Derivation;
const path_mod = @import("../store/path.zig");
const StorePath = path_mod.StorePath;

pub const Resolver = struct {
    gpa: Allocator,
    io: Io,
    /// Owned: `deinit` closes it.
    conn: *Connection,
    /// The derivations read, kept for the resolver's life.
    drv_arena: std.heap.ArenaAllocator,
    /// One attempt's temporaries.
    tmp: Scratch,
    valid: PathMap(bool) = .empty,
    probe: PathMap(bool) = .empty,
    drvs: PathMap(*const Derivation) = .empty,
    wanted_valid: PathSet = .empty,
    wanted: PathSet = .empty,
    attempt_complete: bool = true,
    round_trips: usize = 0,

    pub fn open(gpa: Allocator, io: Io, transport: *const worker.Transport, env: ?*const std.process.Environ.Map, d: *Diag) Error!Resolver {
        const conn = try Connection.open(gpa, io, transport, env, .none, .ignore, d);
        return .init(gpa, io, conn);
    }

    pub fn init(gpa: Allocator, io: Io, conn: *Connection) Resolver {
        return .{ .gpa = gpa, .io = io, .conn = conn, .drv_arena = .init(gpa), .tmp = .init(gpa) };
    }

    pub fn deinit(r: *Resolver) void {
        r.conn.close();
        r.valid.deinit(r.gpa);
        r.probe.deinit(r.gpa);
        r.drvs.deinit(r.gpa);
        r.wanted_valid.deinit(r.gpa);
        r.wanted.deinit(r.gpa);
        r.tmp.deinit();
        r.drv_arena.deinit();
        r.* = undefined;
    }

    /// Fills the cache-status fields of every job in `lines`.
    pub fn resolve(r: *Resolver, lines: []Line, d: *Diag) Error!void {
        var left: std.ArrayList(usize) = .empty;
        defer left.deinit(r.gpa);
        for (lines, 0..) |l, i| if (l == .job) try left.append(r.gpa, i);
        while (left.items.len > 0) {
            var n: usize = 0;
            for (left.items) |i| {
                if (!try r.tryResolve(&lines[i].job, d)) {
                    left.items[n] = i;
                    n += 1;
                }
            }
            left.items.len = n;
            if (n == 0) break;
            if (r.wanted_valid.count() == 0 and r.wanted.count() == 0)
                return d.fail(error.Cache, "cache status resolver made no progress", .{});
            try r.resolveWanted(d);
        }
    }

    /// The paths of `set` in `a`, sorted, the order Rust iets sends them in;
    /// empties `set`.
    fn drain(a: Allocator, set: *PathSet) Allocator.Error![]StorePath {
        const paths = try a.alloc(StorePath, set.count());
        var it = set.keyIterator();
        for (paths) |*p| p.* = it.next().?.*;
        set.clearRetainingCapacity();
        std.mem.sortUnstable(StorePath, paths, {}, StorePath.lessThan);
        return paths;
    }

    /// One `QueryValidPaths` and one `QuerySubstitutablePathInfos` for
    /// everything the last pass asked for.
    fn resolveWanted(r: *Resolver, d: *Diag) Error!void {
        var arena_state: std.heap.ArenaAllocator = .init(r.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        if (r.wanted_valid.count() > 0) {
            const paths = try drain(a, &r.wanted_valid);
            const valid = try r.conn.queryValid(a, paths, .ignore, d);
            r.round_trips += 1;
            const got = try pathSet(a, valid);
            for (paths) |p| try r.valid.put(r.gpa, p, got.contains(p));
        }
        if (r.wanted.count() == 0) return;
        const paths = try drain(a, &r.wanted);
        // Unreachable substituters count as misses.
        const infos = r.conn.querySubstitutablePathInfos(a, paths, .ignore, d) catch |e| blk: {
            if (e == error.OutOfMemory) return e;
            d.deinit();
            break :blk &.{};
        };
        r.round_trips += 1;
        const got = try pathSet(a, infos);
        for (paths) |p| try r.probe.put(r.gpa, p, got.contains(p));
    }

    /// `null` while a path has not been probed yet; it is wanted then.
    fn allSubstitutable(r: *Resolver, paths: []const StorePath) Allocator.Error!?bool {
        var all = true;
        var complete = true;
        for (paths) |p| {
            if (r.probe.get(p)) |has| {
                all = all and has;
            } else {
                try r.wanted.put(r.gpa, p, {});
                r.attempt_complete = false;
                complete = false;
            }
        }
        return if (complete) all else null;
    }

    fn probeValidity(r: *Resolver, p: StorePath) Allocator.Error!?bool {
        if (r.valid.get(p)) |v| return v;
        try r.wanted_valid.put(r.gpa, p, {});
        r.attempt_complete = false;
        return null;
    }

    fn readDerivation(r: *Resolver, p: StorePath, d: *Diag) Error!*const Derivation {
        const gop = try r.drvs.getOrPut(r.gpa, p);
        if (gop.found_existing) return gop.value_ptr.*;
        errdefer r.drvs.removeByPtr(gop.key_ptr);
        const a = r.drv_arena.allocator();
        const drv = try a.create(Derivation);
        drv.* = drv_mod.loadDerivationFromStore(r.io, a, p, d) catch |e| return storeErr(e);
        gop.value_ptr.* = drv;
        return drv;
    }

    const MissingOutputs = struct {
        known: bool = true,
        complete: bool = true,
        missing: std.ArrayList(StorePath) = .empty,
    };

    /// The wanted (or all) output paths of `drv` that are not valid.
    fn missingOutputs(r: *Resolver, drv: *const Derivation, wanted: []const []const u8, d: *Diag) Error!MissingOutputs {
        var m: MissingOutputs = .{};
        for (drv.outputs) |o| {
            if (wanted.len > 0 and !contains(wanted, o.name)) continue;
            const path = switch (o.output) {
                .input_addressed => |p| p,
                .fixed => drv.fixedOutputPath(o.name, d) catch |e| return storeErr(e),
                else => {
                    m.known = false;
                    return m;
                },
            };
            if (try r.probeValidity(path)) |v| {
                if (!v) try m.missing.append(r.tmp.allocator(), path);
            } else m.complete = false;
        }
        return m;
    }

    fn visitDrv(r: *Resolver, t: *Traversal, drv_path: StorePath, wanted: []const []const u8, d: *Diag) Error!void {
        const a = r.tmp.allocator();
        if ((try t.visited.getOrPut(a, drv_path)).found_existing) return;
        const drv = try r.readDerivation(drv_path, d);
        const outputs = try r.missingOutputs(drv, wanted, d);
        if (!outputs.known) return;
        // Validity probes are cheap: recurse anyway so one round covers
        // the closure.
        if (!outputs.complete) {
            for (drv.input_drvs) |in| try r.visitDrv(t, in.path, in.node.outputs, d);
            return;
        }
        if (outputs.missing.items.len == 0) return;
        // Substituter probes are per-path requests: a substitutable
        // derivation's inputs are never probed.
        const substitutable = try r.allSubstitutable(outputs.missing.items) orelse return;
        if (substitutable) {
            for (outputs.missing.items) |p| try t.substitute_paths.put(a, p, {});
            return;
        }
        for (drv.input_drvs) |in| try r.visitDrv(t, in.path, in.node.outputs, d);
        try t.needed_builds.append(a, drv_path);
    }

    /// One attempt with the probes cached so far; `false` when a probe is
    /// still pending (the job is retried after `resolveWanted`).
    fn tryResolve(r: *Resolver, job: *Job, d: *Diag) Error!bool {
        r.tmp.reset();
        const a = r.tmp.allocator();
        r.attempt_complete = true;
        var missing: std.ArrayList(StorePath) = .empty;
        var known = true;
        var complete = true;
        for (job.outputs.items) |o| {
            const path = o.path orelse {
                known = false;
                break;
            };
            if (try r.probeValidity(path)) |v| {
                if (!v) try missing.append(a, path);
            } else complete = false;
        }
        if (known) {
            if (!complete) return false;
            const all = try r.allSubstitutable(missing.items) orelse return false;
            if (all) {
                sortPaths(missing.items);
                try setStatus(r.gpa, job, if (missing.items.len == 0) "local" else "cached", &.{}, missing.items);
                return true;
            }
        }
        var t: Traversal = .{};
        try r.visitDrv(&t, job.drv_path, &.{}, d);
        if (!r.attempt_complete) return false;
        const substitutes = try a.alloc(StorePath, t.substitute_paths.count());
        var it = t.substitute_paths.keyIterator();
        var i: usize = 0;
        while (it.next()) |p| : (i += 1) substitutes[i] = p.*;
        sortPaths(substitutes);
        try setStatus(r.gpa, job, "notBuilt", t.needed_builds.items, substitutes);
        return true;
    }
};

/// One attempt's walk; in the resolver's scratch.
const Traversal = struct {
    visited: PathSet = .empty,
    needed_builds: std.ArrayList(StorePath) = .empty,
    substitute_paths: PathSet = .empty,
};

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn pathSet(a: Allocator, paths: []const StorePath) Allocator.Error!PathSet {
    var s: PathSet = .empty;
    try s.ensureTotalCapacity(a, @intCast(paths.len));
    for (paths) |p| s.putAssumeCapacity(p, {});
    return s;
}

/// A derivation error is a store error; its message is in the `Diag`.
fn storeErr(e: drv_mod.Error) Error {
    return if (e == error.OutOfMemory) error.OutOfMemory else error.Store;
}

/// Deterministic output order: by name, then full path.
fn sortPaths(paths: []StorePath) void {
    std.mem.sortUnstable(StorePath, paths, {}, struct {
        fn lt(_: void, a: StorePath, b: StorePath) bool {
            return switch (std.mem.order(u8, a.name(), b.name())) {
                .lt => true,
                .gt => false,
                // the full paths share the store directory
                .eq => a.order(&b) == .lt,
            };
        }
    }.lt);
}

fn setStatus(gpa: Allocator, job: *Job, status: []const u8, builds: []const StorePath, substitutes: []const StorePath) Allocator.Error!void {
    const cached = !std.mem.eql(u8, status, "notBuilt");
    try job.putExtra(gpa, "isCached", try gpa.dupe(u8, if (cached) "true" else "false"));
    try job.putExtra(gpa, "cacheStatus", try line_mod.jsonStr(gpa, status));
    try job.putExtra(gpa, "neededBuilds", try line_mod.jsonPathList(gpa, builds));
    try job.putExtra(gpa, "neededSubstitutes", try line_mod.jsonPathList(gpa, substitutes));
}

const testing = std.testing;

test "paths sort by name, then by path" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var paths = [_]StorePath{
        try .parse("/nix/store/11111111111111111111111111111111-b", &d),
        try .parse("/nix/store/22222222222222222222222222222222-a", &d),
        try .parse("/nix/store/00000000000000000000000000000000-b", &d),
    };
    sortPaths(&paths);
    try testing.expectEqualStrings("22222222222222222222222222222222-a", paths[0].baseName());
    try testing.expectEqualStrings("00000000000000000000000000000000-b", paths[1].baseName());
    try testing.expectEqualStrings("11111111111111111111111111111111-b", paths[2].baseName());
}

test "the status fields of a job" {
    const gpa = testing.allocator;
    var d: Diag = .init(gpa);
    defer d.deinit();
    var line = try Line.parse(gpa,
        \\{"attr":"a","attrPath":["a"],"constituents":[],"drvPath":"/nix/store/00000000000000000000000000000000-a.drv","globConstituents":false,"outputs":{}}
    , &d);
    defer line.deinit(gpa);
    const p = try StorePath.parse("/nix/store/00000000000000000000000000000000-a", &d);
    try setStatus(gpa, &line.job, "cached", &.{}, &.{p});
    const out = try line.renderAlloc(gpa);
    defer gpa.free(out);
    try testing.expectEqualStrings(
        \\{"attr":"a","attrPath":["a"],"cacheStatus":"cached","constituents":[],"drvPath":"/nix/store/00000000000000000000000000000000-a.drv","globConstituents":false,"isCached":true,"neededBuilds":[],"neededSubstitutes":["/nix/store/00000000000000000000000000000000-a"],"outputs":{}}
    , out);
}

const socket = "/nix/var/nix/daemon-socket/socket";

/// A store path that is surely valid: the system's.
fn someValidPath(buf: []u8) ?[]const u8 {
    for ([_][]const u8{ "/run/current-system/sw", "/run/current-system" }) |link| {
        const n = Io.Dir.cwd().realPathFile(testing.io, link, buf) catch continue;
        const full = buf[0..n];
        const rest = path_mod.stripStoreDir(full) orelse continue;
        const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        return full[0 .. full.len - rest.len + end];
    }
    return null;
}

test "a job whose outputs are valid is local after one round trip" {
    const gpa = testing.allocator;
    Io.Dir.cwd().access(testing.io, socket, .{}) catch return error.SkipZigTest;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const valid = someValidPath(&buf) orelse return error.SkipZigTest;
    var d: Diag = .init(gpa);
    defer d.deinit();
    const t: worker.Transport = .{ .unix = socket };
    var r = try Resolver.open(gpa, testing.io, &t, null, &d);
    defer r.deinit();
    var lines = [_]Line{try Line.parse(gpa,
        \\{"attr":"a","attrPath":["a"],"constituents":[],"drvPath":"/nix/store/00000000000000000000000000000000-a.drv","globConstituents":false,"outputs":{}}
    , &d)};
    defer lines[0].deinit(gpa);
    const job = &lines[0].job;
    try job.putOutput(gpa, "out", try StorePath.parse(valid, &d));
    try r.resolve(&lines, &d);
    try testing.expectEqual(1, r.round_trips);
    try testing.expectEqualStrings("\"local\"", job.getExtra("cacheStatus").?);
    try testing.expectEqualStrings("true", job.getExtra("isCached").?);
    try testing.expectEqualStrings("[]", job.getExtra("neededSubstitutes").?);
}
