//! Memory census behind the `-Dstats2=true` build option and
//! `IETS_STATS=2`: histograms by object kind, duplicate strings and
//! contexts, `//` shapes, and which objects were never read. Every hook is
//! behind the comptime `enabled`, so the default build carries none of it.
//! A census run has one worker.

const std = @import("std");
const value = @import("value.zig");
const fxBytes = @import("../syntax/symbol.zig").fxBytes;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Attrs = value.Attrs;
const Union = value.Union;
const Env = value.Env;
const Ctx = value.Ctx;

/// Whether the census is compiled in.
pub const enabled = @import("build_options").stats2;

pub const size_buckets = [11][]const u8{ "0", "1", "2", "3-4", "5-8", "9-16", "17-32", "33-64", "65-128", "129-256", "257+" };

pub fn sizeBucket(n: usize) usize {
    return switch (n) {
        0 => 0,
        1 => 1,
        2 => 2,
        3...4 => 3,
        5...8 => 4,
        9...16 => 5,
        17...32 => 6,
        33...64 => 7,
        65...128 => 8,
        129...256 => 9,
        else => 10,
    };
}

/// Producers of attrsets, stored in the set's census marks.
pub const origins = [10][]const u8{ "other", "lit", "upd", "mapAttrs", "listToAttrs", "removeAttrs", "zipAttrsWith", "intersect", "groupBy", "pos" };

pub const Origin = enum(u8) { other, lit, upd, map_attrs, list_to_attrs, remove_attrs, zip_attrs_with, intersect, group_by, pos };

/// How `updateAttrs` built a result, in its order of tests.
pub const upd_paths = [5][]const u8{ "empty side", "flat copy", "union", "flatten a, union", "flat, over leaves" };

/// Uses of one `//` result by the end of the run.
pub const upd_uses = [7][]const u8{ "never used", "once: select", "once: iterated", "once: left of //", "once: right of //", "2-3 uses", "4+ uses" };

/// A set's select count (low 7 bits, saturating) and iterated bit.
pub const iterated: u8 = 0x80;

/// Each new `//` result: chain length, uses as left and as right operand.
const UpdResult = struct { chain: u32, left: u32, right: u32 };
const UpdFile = struct { name: []const u8, n: u64, bytes: u64 };
/// The file of a `//`.
pub const UpdSite = struct { id: u32, name: []const u8 };

pub const Upd = struct {
    n: u64 = 0,
    paths: [5]u64 = @splat(0),
    a: [11]u64 = @splat(0),
    b: [11]u64 = @splat(0),
    out: [11]u64 = @splat(0),
    /// Right-hand keys the left side already has, and the ones it adds.
    over: [11]u64 = @splat(0),
    add: [11]u64 = @splat(0),
    /// Overwritten share of the right side: none, under half, half or
    /// more, all.
    over_share: [4]u64 = @splat(0),
    sum_a: u64 = 0,
    sum_b: u64 = 0,
    sum_out: u64 = 0,
    /// Arena bytes the update allocated: copies, flattens, union headers.
    bytes: u64 = 0,
    /// Updates whose right operand is itself a `//` expression: the inner
    /// result is built only to be merged again.
    nested_right: u64 = 0,
    /// Length of the left-nested `//` chain each result ends.
    chain: [11]u64 = @splat(0),
    /// (a bucket, b bucket) counts.
    shape: [11][11]u64 = @splat(@splat(0)),
    results: std.AutoHashMapUnmanaged(usize, UpdResult) = .empty,
    /// By the file of the `//`, keyed by its file id.
    by_file: std.AutoHashMapUnmanaged(u32, UpdFile) = .empty,
};

/// Lookups on a flat set, on a union through its flat copy, on a union over
/// its leaves that hit, the leaves all union lookups probed, and the union
/// lookups that missed. `get` has no arena at hand, hence globals.
pub var gets: [5]std.atomic.Value(u64) = @splat(.init(0));

pub inline fn noteGet(kind: usize, probes: u64) void {
    _ = gets[kind].fetchAdd(1, .monotonic);
    if (probes != 0) _ = gets[3].fetchAdd(probes, .monotonic);
}

const EnvNote = struct { env: *Env, n: u32 };

/// One arena's census. Allocation failures drop a record: the census is
/// a measurement, never a reason to fail the run.
pub const Census = struct {
    gpa: Allocator,
    env_hist: [11][2]u64 = @splat(.{ 0, 0 }),
    attrs_hist: [10][11]u64 = @splat(@splat(0)),
    str_len_hist: [11][2]u64 = @splat(.{ 0, 0 }),
    str_seen: std.AutoHashMapUnmanaged(u64, void) = .empty,
    str_dups: u64 = 0,
    str_dup_bytes: u64 = 0,
    ctx_seen: std.AutoHashMapUnmanaged(u64, void) = .empty,
    ctx_dups: u64 = 0,
    ctx_dup_bytes: u64 = 0,
    ctx_len_hist: [11][2]u64 = @splat(.{ 0, 0 }),
    upd: Upd = .{},
    /// thunk, thunk_app, thunk_app2 (none in this port), thunk_map.
    forced: [4]u64 = @splat(0),
    envs: std.ArrayList(EnvNote) = .empty,
    /// Sets and unions, by their header.
    attrs: std.ArrayList(*value.Obj) = .empty,
    strings: std.ArrayList(*value.String) = .empty,
    lists: std.ArrayList(*value.List) = .empty,
    lambda_closed: u64 = 0,
    get_attr_pos_calls: u64 = 0,
    ir_by_file: std.ArrayList([2]u64) = .empty,
    /// Entry counts of unions, which keep none of their own.
    union_len: std.AutoHashMapUnmanaged(usize, u32) = .empty,
    /// Scoped-release assessment: thunks created inside the open scope, and
    /// forces of older thunks inside it (each one writes a value built
    /// inside the scope into memory that outlives it).
    scope_open: bool = false,
    scope_thunks: std.AutoHashMapUnmanaged(u64, void) = .empty,
    scope_escapes: u64 = 0,
    scope_start: usize = 0,
    /// `tryEval` scopes: calls, failed, bytes inside failed, failed with no
    /// escape and their bytes.
    try_scopes: [5]u64 = @splat(0),
    /// eval-jobs job units: units, bytes, units with no escape, their bytes.
    job_scopes: [4]u64 = @splat(0),

    pub fn init(gpa: Allocator) Census {
        return .{ .gpa = gpa };
    }

    pub fn deinit(c: *Census) void {
        const gpa = c.gpa;
        c.str_seen.deinit(gpa);
        c.ctx_seen.deinit(gpa);
        c.upd.results.deinit(gpa);
        c.upd.by_file.deinit(gpa);
        c.envs.deinit(gpa);
        c.attrs.deinit(gpa);
        c.strings.deinit(gpa);
        c.lists.deinit(gpa);
        c.ir_by_file.deinit(gpa);
        c.union_len.deinit(gpa);
        c.scope_thunks.deinit(gpa);
        c.* = undefined;
    }

    /// Open an escape-tracking scope at `bytes` allocated; false when one is
    /// already open (nested scopes are not tracked).
    pub fn scopeEnter(c: *Census, bytes: usize) bool {
        if (c.scope_open) return false;
        c.scope_open = true;
        c.scope_thunks.clearRetainingCapacity();
        c.scope_escapes = 0;
        c.scope_start = bytes;
        return true;
    }

    /// Close the scope: bytes allocated inside, and escapes.
    pub fn scopeLeave(c: *Census, bytes: usize) struct { u64, u64 } {
        c.scope_open = false;
        return .{ bytes - c.scope_start, c.scope_escapes };
    }

    pub fn noteThunkCreated(c: *Census, w: u64) void {
        if (c.scope_open) c.scope_thunks.put(c.gpa, w, {}) catch {};
    }

    pub fn noteThunkForced(c: *Census, w: u64) void {
        if (c.scope_open and !c.scope_thunks.contains(w)) c.scope_escapes += 1;
    }

    pub fn noteEnv(c: *Census, e: *Env, n: usize) void {
        const b = sizeBucket(n);
        c.env_hist[b][0] += 1;
        c.env_hist[b][1] += 8 + 8 * n;
        c.envs.append(c.gpa, .{ .env = e, .n = @intCast(n) }) catch {};
    }

    /// A fresh set or union of `n` entries; clears its marks.
    pub fn noteAttrs(c: *Census, p: *value.Obj, origin: Origin, n: usize) void {
        const m = value.setMarks(p);
        m.* = .{ .origin = @backingInt(origin) };
        c.attrs_hist[@backingInt(origin)][sizeBucket(n)] += 1;
        c.attrs.append(c.gpa, p) catch {};
    }

    /// A fresh set's producer, once it is known: `allocAttrs` noted it as
    /// `other`.
    pub fn retag(c: *Census, a: *Attrs, origin: Origin) void {
        if (a.len == 0) return; // the shared empty set
        const m = &a.marks;
        if (m.origin != 0) return;
        const b = sizeBucket(a.len);
        c.attrs_hist[0][b] -= 1;
        c.attrs_hist[@backingInt(origin)][b] += 1;
        m.origin = @backingInt(origin);
    }

    pub fn noteList(c: *Census, l: *value.List) void {
        l.flags = 0;
        c.lists.append(c.gpa, l) catch {};
    }

    pub fn noteString(c: *Census, s: *value.String, bytes: []const u8, ctx_bytes: usize) void {
        s.flags = 0;
        const b = sizeBucket(bytes.len);
        c.str_len_hist[b][0] += 1;
        c.str_len_hist[b][1] += bytes.len;
        const seen = c.str_seen.getOrPut(c.gpa, fxBytes(bytes)) catch return;
        if (seen.found_existing) {
            c.str_dups += 1;
            c.str_dup_bytes += bytes.len;
        }
        if (ctx_bytes > 0) {
            const cb = sizeBucket(ctx_bytes / @sizeOf(Ctx));
            c.ctx_len_hist[cb][0] += 1;
            c.ctx_len_hist[cb][1] += ctx_bytes;
        }
        c.strings.append(c.gpa, s) catch {};
    }

    pub fn noteCtx(c: *Census, ctx: []const Ctx) void {
        if (ctx.len == 0) return;
        var key: std.ArrayList(u8) = .empty;
        defer key.deinit(c.gpa);
        for (ctx) |x| {
            const tag: u8 = switch (x.kind) {
                .opaque_path => 1,
                .drv_deep => 2,
                .built => 3,
                .impure_path, .impure_meta => 4,
            };
            key.append(c.gpa, tag) catch return;
            key.appendSlice(c.gpa, x.path) catch return;
            if (x.kind == .built) {
                key.append(c.gpa, 0) catch return;
                key.appendSlice(c.gpa, x.output) catch return;
            }
            key.append(c.gpa, 0) catch return;
        }
        const seen = c.ctx_seen.getOrPut(c.gpa, fxBytes(key.items)) catch return;
        if (seen.found_existing) {
            c.ctx_dups += 1;
            c.ctx_dup_bytes += ctx.len * @sizeOf(Ctx);
        }
    }

    /// Entries of a set or union without marking it used.
    pub fn lenOf(c: *Census, p: *value.Obj) usize {
        if (p.kind != .attrs_union) return @as(*Attrs, @ptrCast(p)).len;
        const u: *Union = @ptrCast(p);
        if (u.flat_cache.load(.acquire)) |f| return f.len;
        const gop = c.union_len.getOrPut(c.gpa, @intFromPtr(u)) catch return countMerged(u.leaves());
        if (!gop.found_existing) gop.value_ptr.* = @intCast(countMerged(u.leaves()));
        return gop.value_ptr.*;
    }

    /// One `a // b` that gave `out`; `bytes` is what it allocated and `file`
    /// the source file of the operator.
    pub fn noteUpd(c: *Census, path: usize, a: *value.Obj, b: *value.Obj, out: *value.Obj, bytes: u64, file: ?UpdSite) void {
        const la = c.lenOf(a);
        const lb = c.lenOf(b);
        const lo = c.lenOf(out);
        const over = la + lb - lo;
        const u = &c.upd;
        u.n += 1;
        u.paths[path] += 1;
        u.a[sizeBucket(la)] += 1;
        u.b[sizeBucket(lb)] += 1;
        u.out[sizeBucket(lo)] += 1;
        u.over[sizeBucket(over)] += 1;
        u.add[sizeBucket(lb - over)] += 1;
        u.over_share[if (over == 0) 0 else if (over == lb) 3 else if (2 * over < lb) 1 else 2] += 1;
        u.sum_a += la;
        u.sum_b += lb;
        u.sum_out += lo;
        u.bytes += bytes;
        u.shape[sizeBucket(la)][sizeBucket(lb)] += 1;
        var chain: u32 = 1;
        if (u.results.getPtr(@intFromPtr(a))) |r| {
            r.left += 1;
            chain += r.chain;
        }
        if (u.results.getPtr(@intFromPtr(b))) |r| r.right += 1;
        if (path != 0) {
            u.chain[sizeBucket(chain)] += 1;
            u.results.put(c.gpa, @intFromPtr(out), .{ .chain = chain, .left = 0, .right = 0 }) catch {};
        }
        if (file) |f| {
            const e = u.by_file.getOrPut(c.gpa, f.id) catch return;
            if (!e.found_existing) e.value_ptr.* = .{ .name = f.name, .n = 0, .bytes = 0 };
            e.value_ptr.n += 1;
            e.value_ptr.bytes += bytes;
        }
    }

    pub fn report(c: *Census, w: *Writer) Writer.Error!void {
        try w.writeAll("--- census (IETS_STATS=2) ---\n");
        try w.writeAll("envs by slot count (count, bytes):\n");
        for (c.env_hist, 0..) |h, i| if (h[0] > 0)
            try w.print("  {s:>8} {d:>10} {d:>12}\n", .{ size_buckets[i], h[0], h[1] });
        // The read mark is bit 0 of `up`, the captured mark bit 1.
        var env_unread: u64 = 0;
        var env_unread_bytes: u64 = 0;
        var env_unread_by: [11]u64 = @splat(0);
        var env_uncaptured_by: [11]u64 = @splat(0);
        var env_uncaptured_bytes: u64 = 0;
        for (c.envs.items) |e| {
            const up = e.env.marks();
            const bytes = 8 + 8 * @as(u64, e.n);
            if (up & 1 == 0) {
                env_unread += 1;
                env_unread_bytes += bytes;
                env_unread_by[sizeBucket(e.n)] += 1;
            }
            if (up & 2 == 0) {
                env_uncaptured_by[sizeBucket(e.n)] += 1;
                env_uncaptured_bytes += bytes;
            }
        }
        try w.print("envs never captured by a thunk, closure or child env ({d} bytes); by slots: ", .{env_uncaptured_bytes});
        try byBucket(w, &env_uncaptured_by);
        try w.print("\nenvs never read: {d} of {d} ({d} bytes); by slots: ", .{ env_unread, c.envs.items.len, env_unread_bytes });
        try byBucket(w, &env_unread_by);
        try w.writeAll("\nattrsets by producer and size (counts):\n");
        try w.print("  {s:>12}", .{""});
        for (size_buckets) |b| try w.print(" {s:>8}", .{b});
        try w.print(" {s:>9}\n", .{"total"});
        for (c.attrs_hist, 0..) |row, o| {
            var total: u64 = 0;
            for (row) |x| total += x;
            if (total == 0) continue;
            try w.print("  {s:>12}", .{origins[o]});
            for (row) |x| try w.print(" {d:>8}", .{x});
            try w.print(" {d:>9}\n", .{total});
        }
        var never: [10]u64 = @splat(0);
        var never_bytes: [10]u64 = @splat(0);
        var once: [10]u64 = @splat(0);
        var iter: [10]u64 = @splat(0);
        var total_bytes: [10]u64 = @splat(0);
        for (c.attrs.items) |a| {
            const m = value.setMarks(a).*;
            const o = m.origin;
            const bytes = 8 + 16 * @as(u64, c.lenOf(a));
            total_bytes[o] += bytes;
            const sel = m.flags & 0x7f;
            const it = m.flags & iterated != 0;
            if (it) iter[o] += 1;
            if (sel == 0 and !it) {
                never[o] += 1;
                never_bytes[o] += bytes;
            } else if (sel == 1 and !it) once[o] += 1;
        }
        try w.writeAll("attrsets use: producer: total bytes / never selected nor iterated (bytes) / selected once only / iterated\n");
        for (0..10) |o| {
            if (total_bytes[o] == 0) continue;
            try w.print("  {s:>12}: {d:>11} / {d:>8} ({d:>10}) / {d:>8} / {d:>8}\n", .{ origins[o], total_bytes[o], never[o], never_bytes[o], once[o], iter[o] });
        }
        const u = &c.upd;
        const n: f64 = @floatFromInt(@max(u.n, 1));
        try w.print("update (//): n={d} allocated={d} bytes; right operand a // expression: {d}; mean a={d:.1} b={d:.1} out={d:.1}\n", .{
            u.n,
            u.bytes,
            u.nested_right,
            @as(f64, @floatFromInt(u.sum_a)) / n,
            @as(f64, @floatFromInt(u.sum_b)) / n,
            @as(f64, @floatFromInt(u.sum_out)) / n,
        });
        try w.writeAll("update paths:");
        for (upd_paths, u.paths) |name, x| try w.print(" {s}={d}", .{ name, x });
        try w.writeAll("\nupdate sizes (counts):\n");
        try w.print("  {s:>12}", .{""});
        for (size_buckets) |b| try w.print(" {s:>8}", .{b});
        try w.writeAll("\n");
        const rows = [_]struct { []const u8, *const [11]u64 }{
            .{ "left", &u.a },
            .{ "right", &u.b },
            .{ "result", &u.out },
            .{ "overwritten", &u.over },
            .{ "added", &u.add },
            .{ "chain", &u.chain },
        };
        for (rows) |r| {
            try w.print("  {s:>12}", .{r[0]});
            for (r[1]) |x| try w.print(" {d:>8}", .{x});
            try w.writeAll("\n");
        }
        try w.print("update right side overwritten: none={d} under half={d} half or more={d} all={d}\n", .{ u.over_share[0], u.over_share[1], u.over_share[2], u.over_share[3] });
        var uses: [7]u64 = @splat(0);
        var rit = u.results.iterator();
        while (rit.next()) |e| {
            const flags = value.setMarks(@ptrFromInt(e.key_ptr.*)).flags;
            const sel: u32 = flags & 0x7f;
            const it: u32 = flags >> 7;
            const left = e.value_ptr.left;
            const total = sel + it + left + e.value_ptr.right;
            uses[
                if (total == 0) 0 else if (total == 1) (if (sel == 1) 1 else if (it == 1) 2 else if (left == 1) 3 else 4) else if (total <= 3) 5 else 6
            ] += 1;
        }
        try w.print("update results by use ({d}):", .{u.results.count()});
        for (upd_uses, uses) |name, x| try w.print(" {s}={d}", .{ name, x });
        var g: [5]u64 = undefined;
        for (&g, &gets) |*x, *a| x.* = a.load(.monotonic);
        try w.print("\nattrset lookups: flat={d} union via flat copy={d} union over leaves: hit={d} miss={d} (leaves probed {d})\n", .{ g[0], g[1], g[2], g[4], g[3] });
        {
            var files: std.ArrayList(UpdFile) = .empty;
            defer files.deinit(c.gpa);
            var fit = u.by_file.valueIterator();
            while (fit.next()) |f| files.append(c.gpa, f.*) catch break;
            std.mem.sort(UpdFile, files.items, {}, struct {
                fn more(_: void, x: UpdFile, y: UpdFile) bool {
                    if (x.n != y.n) return x.n > y.n;
                    return std.mem.lessThan(u8, x.name, y.name);
                }
            }.more);
            try w.writeAll("update by file of the // (count, bytes):\n");
            for (files.items[0..@min(files.items.len, 20)]) |f|
                try w.print("  {d:>9} {d:>11} {s}\n", .{ f.n, f.bytes, f.name });
        }
        try w.writeAll("update shape (rows: a size, cols: b size):\n");
        try w.print("  {s:>8}", .{""});
        for (size_buckets) |b| try w.print(" {s:>8}", .{b});
        try w.writeAll("\n");
        for (u.shape, 0..) |row, i| {
            var sum: u64 = 0;
            for (row) |x| sum += x;
            if (sum == 0) continue;
            try w.print("  {s:>8}", .{size_buckets[i]});
            for (row) |x| try w.print(" {d:>8}", .{x});
            try w.writeAll("\n");
        }
        try w.writeAll("strings by length (count, bytes):\n");
        for (c.str_len_hist, 0..) |h, i| if (h[0] > 0)
            try w.print("  {s:>8} {d:>10} {d:>12}\n", .{ size_buckets[i], h[0], h[1] });
        var str_unread: u64 = 0;
        for (c.strings.items) |s| {
            if (@atomicLoad(u8, &s.flags, .monotonic) == 0) str_unread += 1;
        }
        try w.print("strings: duplicates by content: {d} ({d} bytes); never viewed as a string: {d} of {d}\n", .{ c.str_dups, c.str_dup_bytes, str_unread, c.strings.items.len });
        try w.writeAll("contexts by element count (count, bytes):\n");
        for (c.ctx_len_hist, 0..) |h, i| if (h[0] > 0)
            try w.print("  {s:>8} {d:>10} {d:>12}\n", .{ size_buckets[i], h[0], h[1] });
        try w.print("contexts: duplicates by content: {d} ({d} bytes)\n", .{ c.ctx_dups, c.ctx_dup_bytes });
        try w.print("thunks forced: thunk={d} thunk_app={d} thunk_app2={d} thunk_map={d}\n", .{ c.forced[0], c.forced[1], c.forced[2], c.forced[3] });
        var list_unread: u64 = 0;
        var list_unread_bytes: u64 = 0;
        for (c.lists.items) |l| {
            if (@atomicLoad(u8, &l.flags, .monotonic) == 0) {
                list_unread += 1;
                list_unread_bytes += 8 + 8 * @as(u64, l.len);
            }
        }
        try w.print("lists never read: {d} of {d} ({d} bytes)\n", .{ list_unread, c.lists.items.len, list_unread_bytes });
        try w.print("closures of closed lambdas (no captured variables): {d}\n", .{c.lambda_closed});
        try w.print("unsafeGetAttrPos calls: {d}\n", .{c.get_attr_pos_calls});
        const t = &c.try_scopes;
        try w.print("tryEval scopes (outermost): calls={d} failed={d} bytes inside failed={d} failed without escape={d} ({d} bytes)\n", .{ t[0], t[1], t[2], t[3], t[4] });
        const j = &c.job_scopes;
        try w.print("eval-jobs units: {d} ({d} bytes inside); without escape: {d} ({d} bytes)\n", .{ j[0], j[1], j[2], j[3] });
        const files: [][2]u64 = c.gpa.dupe([2]u64, c.ir_by_file.items) catch &.{};
        defer c.gpa.free(files);
        std.mem.sort([2]u64, files, {}, struct {
            fn more(_: void, x: [2]u64, y: [2]u64) bool {
                return x[1] > y[1];
            }
        }.more);
        var total: u64 = 0;
        for (files) |f| total += f[1];
        try w.print("ir bytes: total {d} over {d} files; top files:\n", .{ total, files.len });
        for (files[0..@min(files.len, 12)]) |f| try w.print("  file{d} {d}\n", .{ f[0], f[1] });
    }
};

/// `bucket=count` for every bucket that is not empty.
fn byBucket(w: *Writer, counts: []const u64) Writer.Error!void {
    var first = true;
    for (counts, 0..) |x, i| {
        if (x == 0) continue;
        if (!first) try w.writeByte(' ');
        first = false;
        try w.print("{s}={d}", .{ size_buckets[i], x });
    }
}

/// Distinct names over sorted leaves: the entry count of their merge.
pub fn countMerged(ls: []const *Attrs) usize {
    var heads: [Union.max_leaves]usize = @splat(0);
    var n: usize = 0;
    while (true) {
        var min: u32 = std.math.maxInt(u32);
        var any = false;
        for (ls, 0..) |l, k| if (heads[k] < l.len) {
            any = true;
            min = @min(min, @backingInt(l.raw()[heads[k]].sym));
        };
        if (!any) return n;
        n += 1;
        for (ls, 0..) |l, k| {
            if (heads[k] < l.len and @backingInt(l.raw()[heads[k]].sym) == min) heads[k] += 1;
        }
    }
}

/// The branch `updateAttrs` takes; read before the update, which may cache
/// a flat copy of `a`.
pub fn updPath(a: value.Value, b: value.Value) usize {
    const ua = a.asUnion();
    const ub = b.asUnion();
    if ((ua == null and a.as(Attrs).len == 0) or (ub == null and b.as(Attrs).len == 0)) return 0;
    if (ua == null and a.as(Attrs).len < Union.min_left) return 1;
    const la = leafCount(ua);
    const lb = leafCount(ub);
    if (la + lb <= Union.max_leaves) return 2;
    return if (1 + lb <= Union.max_leaves) 3 else 4;
}

fn leafCount(u: ?*Union) usize {
    const x = u orelse return 1;
    return if (x.flat_cache.load(.acquire) != null) 1 else x.nleaves;
}

test "size buckets" {
    const t = std.testing;
    const want = [_]struct { usize, usize }{ .{ 0, 0 }, .{ 1, 1 }, .{ 2, 2 }, .{ 3, 3 }, .{ 4, 3 }, .{ 5, 4 }, .{ 8, 4 }, .{ 9, 5 }, .{ 16, 5 }, .{ 17, 6 }, .{ 64, 7 }, .{ 65, 8 }, .{ 256, 9 }, .{ 257, 10 }, .{ 1 << 20, 10 } };
    for (want) |x| try t.expectEqual(x[1], sizeBucket(x[0]));
}

test "byBucket" {
    var buf: [64]u8 = undefined;
    var w: Writer = .fixed(&buf);
    var counts: [11]u64 = @splat(0);
    counts[0] = 2;
    counts[3] = 5;
    counts[10] = 1;
    try byBucket(&w, &counts);
    try std.testing.expectEqualStrings("0=2 3-4=5 257+=1", w.buffered());
}

test "escape scopes" {
    var c: Census = .init(std.testing.allocator);
    defer c.deinit();
    try std.testing.expect(c.scopeEnter(100));
    // nested scopes are not tracked
    try std.testing.expect(!c.scopeEnter(150));
    c.noteThunkCreated(0x1002);
    c.noteThunkForced(0x1002);
    c.noteThunkForced(0x2002);
    const bytes, const escapes = c.scopeLeave(164);
    try std.testing.expectEqual(64, bytes);
    try std.testing.expectEqual(1, escapes);
    // closed: nothing is tracked
    c.noteThunkForced(0x3002);
    try std.testing.expectEqual(1, c.scope_escapes);
}

test "merged leaf counts" {
    const t = std.testing;
    const Sym = @import("../syntax/symbol.zig").Sym;
    const mk = struct {
        fn f(gpa: Allocator, ids: []const u32) !*Attrs {
            const bytes = try gpa.alignedAlloc(u8, .of(Attrs), @sizeOf(Attrs) + ids.len * @sizeOf(value.Attr));
            const a: *Attrs = @ptrCast(bytes.ptr);
            a.* = .{ .len = @intCast(ids.len) };
            for (a.raw(), ids) |*e, id| e.* = .{ .sym = @as(Sym, @fromBackingInt(id)), .pos = .none, .cell = .init(.null) };
            return a;
        }
        fn free(gpa: Allocator, a: *Attrs) void {
            const p: [*]align(8) u8 = @ptrCast(a);
            gpa.free(p[0 .. @sizeOf(Attrs) + a.len * @sizeOf(value.Attr)]);
        }
    };
    const a = try mk.f(t.allocator, &.{ 1, 3, 5, 7 });
    defer mk.free(t.allocator, a);
    const b = try mk.f(t.allocator, &.{ 2, 3, 8 });
    defer mk.free(t.allocator, b);
    const e = try mk.f(t.allocator, &.{});
    defer mk.free(t.allocator, e);
    try t.expectEqual(6, countMerged(&.{ a, b }));
    try t.expectEqual(6, countMerged(&.{ a, e, b, a }));
    try t.expectEqual(0, countMerged(&.{e}));
}

test "duplicate strings and contexts" {
    if (!enabled) return error.SkipZigTest;
    const t = std.testing;
    var c: Census = .init(t.allocator);
    defer c.deinit();
    var s1: value.String = .{ .ptr = "abc", .len = 3, .ctx_ptr = undefined, .ctx_len = 0 };
    var s2 = s1;
    var s3: value.String = .{ .ptr = "abcd", .len = 4, .ctx_ptr = undefined, .ctx_len = 0 };
    c.noteString(&s1, "abc", 0);
    c.noteString(&s2, "abc", 0);
    c.noteString(&s3, "abcd", 2 * @sizeOf(Ctx));
    try t.expectEqual(1, c.str_dups);
    try t.expectEqual(3, c.str_dup_bytes);
    try t.expectEqual(3, c.str_len_hist[3][0]);
    try t.expectEqual(10, c.str_len_hist[3][1]);
    try t.expectEqual(1, c.ctx_len_hist[2][0]);
    const x = [_]Ctx{ .{ .kind = .opaque_path, .path = "/nix/store/a" }, .{ .kind = .built, .path = "/nix/store/b.drv", .output = "out" } };
    const y = [_]Ctx{ .{ .kind = .drv_deep, .path = "/nix/store/a" }, .{ .kind = .built, .path = "/nix/store/b.drv", .output = "out" } };
    c.noteCtx(&x);
    c.noteCtx(&y);
    c.noteCtx(&x);
    c.noteCtx(&.{});
    try t.expectEqual(1, c.ctx_dups);
    try t.expectEqual(2 * @sizeOf(Ctx), c.ctx_dup_bytes);
    var out: Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try c.report(&out.writer);
    const text = out.written();
    try t.expect(std.mem.startsWith(u8, text, "--- census (IETS_STATS=2) ---\n"));
    try t.expect(std.mem.indexOf(u8, text, "strings: duplicates by content: 1 (3 bytes); never viewed as a string: 3 of 3\n") != null);
    try t.expect(std.mem.indexOf(u8, text, "contexts: duplicates by content: 1 (80 bytes)\n") != null);
    try t.expect(std.mem.indexOf(u8, text, "ir bytes: total 0 over 0 files; top files:\n") != null);
}
