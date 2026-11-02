//! Copying a closure from one worker-protocol store into another. A remote
//! `builder` leaves its outputs on its own store, so an out-link or a GC root
//! on the local daemon needs them registered locally first
//! (docs/reference/classic.md).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Diag = @import("../diag.zig").Diag;
const remote = @import("../remote.zig");
const Error = remote.Error;
const path_mod = @import("../store/path.zig");
const StorePath = path_mod.StorePath;
const event = @import("event.zig");
const worker = @import("worker.zig");
const wire = worker.wire;
const plan = @import("plan.zig");
const PathInfo = @import("grpc/drvwire.zig").PathInfo;

pub const Infos = plan.PathMap(PathInfo);

/// Registers the closure of `paths`, read from `from`, into `to`, references
/// first. Returns how many paths were added; what `to` has already is left
/// alone. The signature check is waived, which the daemon grants a trusted
/// client only, so an unsigned output of a remote builder still lands.
pub fn closure(
    gpa: Allocator,
    from: *worker.Connection,
    from_uri: []const u8,
    to: *worker.Connection,
    paths: []const StorePath,
    log: remote.Log,
    on_event: event.Sink,
    d: *Diag,
) Error!usize {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var infos = try remoteClosure(gpa, arena, from, paths, on_event, d);
    defer infos.deinit(gpa);
    var valid: plan.PathSet = .empty;
    defer valid.deinit(gpa);
    for (try to.queryValid(arena, try keys(arena, &infos), on_event, d)) |v| try valid.put(gpa, v, {});
    var order: std.ArrayList(StorePath) = .empty;
    for (try topoSort(gpa, arena, &infos)) |p| if (!valid.contains(p)) try order.append(arena, p);
    if (order.items.len == 0) return 0;

    var copying: Copying = .init(log, order.items.len, from_uri, "daemon");
    defer copying.end();
    var up = try to.addMultipleToStore(true, d);
    const w = up.writer();
    wire.writeU64(w, order.items.len) catch |e| return up.fail(e, d);
    var buf: [path_mod.max_base_len + 256]u8 = undefined;
    for (order.items) |*p| {
        const act = copying.path(p.print(&buf));
        defer act.end();
        const info = infos.getPtr(p.*).?;
        info.write(w) catch |e| return up.fail(e, d);
        copyNar(from, p, info.nar_size, w, d) catch |e| return up.fail(e, d);
    }
    try up.finish(on_event, d);
    return order.items.len;
}

/// The paths of `infos`, in `arena`.
pub fn keys(arena: Allocator, infos: *const Infos) Allocator.Error![]StorePath {
    const out = try arena.alloc(StorePath, infos.count());
    var it = infos.keyIterator();
    for (out) |*p| p.* = it.next().?.*;
    return out;
}

/// Copies exactly the announced `size` of `p`'s NAR on `from` into `w`.
fn copyNar(from: *worker.Connection, p: *const StorePath, size: u64, w: *Io.Writer, d: *Diag) Error!void {
    const r = try from.narReader(p, .ignore, d);
    var total: u64 = 0;
    while (total < size) {
        total += r.stream(w, .limited64(size - total)) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return from.narFail(e, d),
        };
    }
    if (total != size)
        return from.narFail(d.fail(error.Io, "'{f}': the NAR was {d} bytes, not the {d} its path info promised", .{ p, total, size }), d);
}

/// The closure of `paths` on `from`, as path infos. `ultimate` is cleared,
/// as store-api.cc:copyStorePath does: the copy was not built here.
fn remoteClosure(gpa: Allocator, arena: Allocator, from: *worker.Connection, paths: []const StorePath, on_event: event.Sink, d: *Diag) Error!Infos {
    var infos: Infos = .empty;
    errdefer infos.deinit(gpa);
    // a BTreeSet: the smallest first
    var queue: std.PriorityQueue(StorePath, void, struct {
        fn order(_: void, a: StorePath, b: StorePath) std.math.Order {
            return a.order(&b);
        }
    }.order) = .empty;
    defer queue.deinit(gpa);
    var queued: plan.PathSet = .empty;
    defer queued.deinit(gpa);
    for (paths) |p| if ((try queued.fetchPut(gpa, p, {})) == null) try queue.push(gpa, p);
    var pbuf: [path_mod.max_base_len + 256]u8 = undefined;
    while (queue.pop()) |p| {
        if (infos.contains(p)) continue;
        var info = (try from.queryPathInfo(arena, p.print(&pbuf), on_event, d)) orelse
            return d.fail(error.Protocol, "'{f}' is not valid on the builder, so it cannot be copied back", .{&p});
        info.ultimate = false;
        for (info.references) |r| {
            const rp = StorePath.parse(r, d) catch return error.Store;
            if (!infos.contains(rp) and (try queued.fetchPut(gpa, rp, {})) == null) try queue.push(gpa, rp);
        }
        try infos.put(gpa, p, info);
    }
    return infos;
}

/// `infos`' paths with every reference ahead of the path that names it, in
/// `arena`.
pub fn topoSort(gpa: Allocator, arena: Allocator, infos: *const Infos) Allocator.Error![]StorePath {
    var out: std.ArrayList(StorePath) = try .initCapacity(arena, infos.count());
    var seen: plan.PathSet = .empty;
    defer seen.deinit(gpa);
    var roots: std.ArrayList(StorePath) = .empty;
    defer roots.deinit(gpa);
    var it = infos.keyIterator();
    while (it.next()) |k| try roots.append(gpa, k.*);
    std.mem.sortUnstable(StorePath, roots.items, {}, StorePath.lessThan);
    const Item = struct { p: StorePath, expanded: bool };
    var stack: std.ArrayList(Item) = .empty;
    defer stack.deinit(gpa);
    var scratch: Diag = .init(gpa);
    defer scratch.deinit();
    for (roots.items) |root| {
        try stack.append(gpa, .{ .p = root, .expanded = false });
        while (stack.pop()) |e| {
            if (e.expanded) {
                try out.append(arena, e.p);
                continue;
            }
            if ((try seen.fetchPut(gpa, e.p, {})) != null) continue;
            try stack.append(gpa, .{ .p = e.p, .expanded = true });
            const info = infos.getPtr(e.p) orelse continue;
            for (info.references) |r| {
                const rp = StorePath.parse(r, &scratch) catch continue;
                if (!rp.eql(&e.p) and !seen.contains(rp)) try stack.append(gpa, .{ .p = rp, .expanded = false });
            }
        }
    }
    return out.items;
}

/// store-api.cc:copyPaths as the log shows it: `copying N paths`, and a
/// `copying path` activity per path while it goes out.
pub const Copying = struct {
    log: remote.Log,
    all: remote.Activity,
    n: usize,
    done: usize = 0,
    from: []const u8,
    to: []const u8,

    pub fn init(log: remote.Log, n: usize, from: []const u8, to: []const u8) Copying {
        var buf: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "copying {d} paths", .{n}) catch unreachable;
        return .{
            .log = log,
            .all = log.activity(0, remote.lvl_info, remote.act_copy_paths, text, &.{}),
            .n = n,
            .from = from,
            .to = to,
        };
    }

    pub fn end(c: *Copying) void {
        c.all.end();
    }

    /// `path` goes out until the returned activity ends; the text is
    /// store-api.cc:makeCopyPathMessage's.
    pub fn path(c: *Copying, p: []const u8) remote.Activity {
        c.all.result(remote.res_progress, &.{ .{ .int = c.done }, .{ .int = c.n }, .{ .int = 1 }, .{ .int = 0 } });
        c.done += 1;
        if (c.log.log == null) return .{ .log = c.log, .id = 0 };
        var buf: [4096]u8 = undefined;
        const text = (if (std.mem.eql(u8, c.from, "local"))
            std.fmt.bufPrint(&buf, "copying path '{s}' to '{s}'", .{ p, c.to })
        else if (std.mem.eql(u8, c.to, "daemon"))
            std.fmt.bufPrint(&buf, "copying path '{s}' from '{s}'", .{ p, c.from })
        else
            std.fmt.bufPrint(&buf, "copying path '{s}' from '{s}' to '{s}'", .{ p, c.from, c.to })) catch &buf;
        return c.log.activity(c.all.id, remote.lvl_info, remote.act_copy_path, text, &.{ .{ .string = p }, .{ .string = c.from }, .{ .string = c.to } });
    }
};

// Tests

const testing = std.testing;

fn testInfo(name: []const u8, refs: []const []const u8) !PathInfo {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    return .{
        .path = try StorePath.fromBaseName(name, &d),
        .deriver = "",
        .nar_hash = "",
        .references = refs,
        .registration_time = 0,
        .nar_size = 0,
        .ultimate = false,
        .sigs = &.{},
        .ca = "",
    };
}

test "topo sort puts references first" {
    const a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-a";
    const b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-b";
    const c = "cccccccccccccccccccccccccccccccc-c";
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var infos: Infos = .empty;
    defer infos.deinit(testing.allocator);
    for ([_]PathInfo{ try testInfo(a, &.{"/nix/store/" ++ b}), try testInfo(b, &.{"/nix/store/" ++ c}), try testInfo(c, &.{}) }) |i|
        try infos.put(testing.allocator, i.path, i);
    const order = try topoSort(testing.allocator, arena.allocator(), &infos);
    try testing.expectEqual(3, order.len);
    try testing.expectEqualStrings(c, order[0].baseName());
    try testing.expectEqualStrings(b, order[1].baseName());
    try testing.expectEqualStrings(a, order[2].baseName());
}

test "a self reference does not loop" {
    const a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-a";
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var infos: Infos = .empty;
    defer infos.deinit(testing.allocator);
    const i = try testInfo(a, &.{"/nix/store/" ++ a});
    try infos.put(testing.allocator, i.path, i);
    try testing.expectEqual(1, (try topoSort(testing.allocator, arena.allocator(), &infos)).len);
}
