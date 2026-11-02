//! Getting what a batch of derivations needs onto the builder, over the
//! backend the builds themselves use.
//!
//! Two shapes. `PlanUpload` ships a `remote.plan.Plan` computed once, for
//! the commands that evaluate to a fixed set of roots before they build
//! anything (`iets build`, `nix-build`, `nix build`). `StreamUpload` is
//! incremental, for the eval-jobs walk that hands over jobs while it runs:
//! per batch it walks only the part of the closure it has not registered
//! yet, one `QueryValidPaths` and one `AddMultipleToStore`. The walk
//! duplicates `plan.plan` on purpose: `plan` has no way to prune at a drv
//! already known valid, and re-planning a whole closure per batch is
//! quadratic on a big `checks` set.
//!
//! Neither shape knows the transport: both speak `backend.Backend`, so the
//! same upload runs over the worker protocol and over `grpc://`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Diag = @import("../diag.zig").Diag;
const remote = @import("../remote.zig");
const plan = remote.plan;
const Plan = plan.Plan;
const Object = plan.Object;
const Sink = remote.event.Sink;
const StorePath = @import("../store/path.zig").StorePath;
const SourceOrigin = @import("../store/source.zig").SourceOrigin;
const locate = @import("../store/locate.zig");
const backend = @import("backend.zig");
const Backend = backend.Backend;
const Drv = backend.Drv;

pub const Error = remote.Error;

pub const Stats = struct {
    batches: usize = 0,
    queried: usize = 0,
    added: usize = 0,
    bytes: u64 = 0,
    substituted: usize = 0,
    /// Nanoseconds.
    time: u64 = 0,

    pub fn merge(s: *Stats, o: Stats) void {
        s.batches += o.batches;
        s.queried += o.queried;
        s.added += o.added;
        s.bytes += o.bytes;
        s.substituted += o.substituted;
        s.time += o.time;
    }
};

/// Registers everything `roots` need that the builder lacks.
pub const Uploader = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        upload: *const fn (*anyopaque, Backend, []const StorePath, Sink, *Diag) Error!Stats,
        /// The derivations `roots` name, and with `deep` everything they need
        /// as well, references before referrers, in `arena`: what a backend
        /// that reports outputs itself, or schedules the builds itself,
        /// drives. The worker backend never asks, so neither walk costs
        /// anything there.
        drvs: *const fn (*anyopaque, []const StorePath, bool, Allocator, *Diag) anyerror![]const Drv,
        /// The store was asked about `roots` already and holds `valid` of them.
        rootsAnswered: *const fn (*anyopaque, []const StorePath, *const plan.NameSet) Allocator.Error!void,
    };

    pub fn of(comptime T: type, p: *T) Uploader {
        const V = struct {
            fn self(c: *anyopaque) *T {
                return @ptrCast(@alignCast(c));
            }
            fn upload(c: *anyopaque, b: Backend, roots: []const StorePath, s: Sink, d: *Diag) Error!Stats {
                return self(c).upload(b, roots, s, d);
            }
            fn drvs(c: *anyopaque, roots: []const StorePath, deep: bool, a: Allocator, d: *Diag) anyerror![]const Drv {
                return self(c).drvs(roots, deep, a, d);
            }
            fn rootsAnswered(c: *anyopaque, roots: []const StorePath, valid: *const plan.NameSet) Allocator.Error!void {
                return self(c).rootsAnswered(roots, valid);
            }
        };
        const W = struct {
            const vtable: VTable = .{ .upload = V.upload, .drvs = V.drvs, .rootsAnswered = V.rootsAnswered };
        };
        return .{ .ptr = p, .vtable = &W.vtable };
    }

    pub fn upload(u: Uploader, b: Backend, roots: []const StorePath, on_event: Sink, d: *Diag) Error!Stats {
        return u.vtable.upload(u.ptr, b, roots, on_event, d);
    }
    pub fn drvs(u: Uploader, roots: []const StorePath, deep: bool, arena: Allocator, d: *Diag) anyerror![]const Drv {
        return u.vtable.drvs(u.ptr, roots, deep, arena, d);
    }
    pub fn rootsAnswered(u: Uploader, roots: []const StorePath, valid: *const plan.NameSet) Allocator.Error!void {
        return u.vtable.rootsAnswered(u.ptr, roots, valid);
    }
};

fn now(io: Io) u64 {
    return @intCast(Io.Clock.awake.now(io).toNanoseconds());
}

/// A closure planned once, shipped on the first call.
pub const PlanUpload = struct {
    gpa: Allocator,
    io: Io,
    plan: *Plan,
    locate: plan.Locator,
    done: bool = false,
    /// What the store said of the roots, in `answered_arena`.
    answered: ?plan.NameSet = null,
    answered_arena: std.heap.ArenaAllocator,

    pub fn init(gpa: Allocator, io: Io, p: *Plan, loc: plan.Locator) PlanUpload {
        return .{ .gpa = gpa, .io = io, .plan = p, .locate = loc, .answered_arena = .init(gpa) };
    }

    pub fn deinit(u: *PlanUpload) void {
        u.answered_arena.deinit();
    }

    pub fn uploader(u: *PlanUpload) Uploader {
        return .of(PlanUpload, u);
    }

    pub fn upload(u: *PlanUpload, b: Backend, roots: []const StorePath, on_event: Sink, d: *Diag) Error!Stats {
        if (u.done or roots.len == 0) return .{};
        u.done = true;
        const t0 = now(u.io);
        var arena_state: std.heap.ArenaAllocator = .init(u.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const Q = struct {
            b: Backend,
            on_event: Sink,
            d: *Diag,
            queried: usize = 0,
            fn f(ctx: ?*anyopaque, paths: []const StorePath, valid: *plan.NameSet, a: Allocator) anyerror!void {
                const q: *@This() = @ptrCast(@alignCast(ctx.?));
                q.queried += paths.len;
                var got = try q.b.queryValid(a, paths, q.on_event, q.d);
                defer got.deinit(a);
                var it = got.keyIterator();
                while (it.next()) |k| try valid.put(a, k.*, {});
            }
        };
        var q: Q = .{ .b = b, .on_event = on_event, .d = d };
        const answered: ?*const plan.NameSet = if (u.answered) |*x| x else null;
        var missing = u.plan.queryMissing(u.gpa, roots, answered, .{ .ctx = &q, .f = Q.f }, d) catch |e| return mapErr(e, d);
        defer missing.deinit(u.gpa);
        const p = u.plan;
        var missing_sources: std.ArrayList(StorePath) = .empty;
        for (p.sources, 0..) |s, i| if (missing.contains(@intCast(i))) try missing_sources.append(arena, s);
        var missing_drvs: std.ArrayList(*Object) = .empty;
        for (p.drvs, 0..) |*o, i| if (missing.contains(@intCast(p.sources.len + i))) try missing_drvs.append(arena, o);

        const t1 = now(u.io);
        const resolved = p.resolve(u.gpa, u.io, missing_sources.items, u.locate, d) catch |e| return mapErr(e, d);
        b.noteUpload(.{
            .missing = missing_sources.items.len + missing_drvs.items.len,
            .resolve_ns = now(u.io) - t1,
            .resolve_paths = resolved.objects.len,
            .store_sources = resolved.store_sources,
        });

        try b.substitute(resolved.substitute, on_event, d);

        var all: std.ArrayList(*Object) = .empty;
        for (resolved.objects) |*o| try all.append(arena, o);
        try all.appendSlice(arena, missing_drvs.items);
        const bytes = try b.addObjects(all.items, on_event, d);
        return .{
            .batches = 1,
            .queried = q.queried,
            .added = all.items.len,
            .bytes = bytes,
            .substituted = resolved.substitute.len,
            .time = now(u.io) - t0,
        };
    }

    pub fn rootsAnswered(u: *PlanUpload, _: []const StorePath, valid: *const plan.NameSet) Allocator.Error!void {
        const a = u.answered_arena.allocator();
        var copy: plan.NameSet = .empty;
        var it = valid.keyIterator();
        while (it.next()) |k| try copy.put(a, try a.dupe(u8, k.*), {});
        u.answered = copy;
    }

    /// The plan is the closure of every root, in post-order already.
    pub fn drvs(u: *PlanUpload, roots: []const StorePath, deep: bool, arena: Allocator, _: *Diag) anyerror![]const Drv {
        var out: std.ArrayList(Drv) = .empty;
        for (u.plan.drvs) |*o| switch (o.*) {
            .drv => |v| {
                if (!deep and !containsPath(roots, v.path)) continue;
                try out.append(arena, .{ .path = v.path, .aterm = v.aterm });
            },
            .source => {},
        };
        return out.items;
    }
};

fn containsPath(list: []const StorePath, p: StorePath) bool {
    for (list) |x| if (x.eql(&p)) return true;
    return false;
}

/// A planning failure keeps its own error; anything else from a callback is
/// an I/O failure that already has its message, or gets one.
fn mapErr(e: anyerror, d: *Diag) Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Io, error.Protocol, error.Usage, error.Store, error.Plan, error.Canceled => @errorCast(e),
        else => if (d.msg != null) error.Io else remote.failIo(d, e, "upload", .{}),
    };
}

/// The incremental one: the evaluation's tables plus what the builder is
/// already known to hold.
pub const StreamUpload = struct {
    gpa: Allocator,
    io: Io,
    inputs: plan.Inputs,
    /// How to run `nix path-info` for a source the evaluation did not add.
    nix: locate.Nix,
    valid: plan.PathSet = .empty,
    /// What the uploaded objects point into: a `grpc://` store's `NOT_FOUND`
    /// retry sends them again, so they live as long as the upload.
    keep: std.heap.ArenaAllocator,

    pub fn init(gpa: Allocator, io: Io, inputs: plan.Inputs, nix: locate.Nix) StreamUpload {
        return .{ .gpa = gpa, .io = io, .inputs = inputs, .nix = nix, .keep = .init(gpa) };
    }

    pub fn deinit(u: *StreamUpload) void {
        u.valid.deinit(u.gpa);
        u.keep.deinit();
    }

    pub fn uploader(u: *StreamUpload) Uploader {
        return .of(StreamUpload, u);
    }

    /// Where to read a source and how it was addressed: from the
    /// evaluation, else from the local store, else null and the builder
    /// substitutes it.
    fn sourceInfo(u: *StreamUpload, arena: Allocator, p: StorePath, d: *Diag) Error!?SourceOrigin {
        if (u.inputs.getSource(&p)) |o| return o;
        var out: [1]?SourceOrigin = undefined;
        const none: locate.Overrides = .empty;
        locate.locateInStore(arena, u.nix, &.{p}, &none, &out, d) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.Io => error.Io,
            error.Protocol => error.Protocol,
            error.Store => error.Store,
        };
        return out[0];
    }

    pub fn upload(u: *StreamUpload, b: Backend, roots: []const StorePath, on_event: Sink, d: *Diag) Error!Stats {
        const t0 = now(u.io);
        var st: Stats = .{ .batches = 1 };
        const arena = u.keep.allocator();
        const w = plan.walk(u.gpa, arena, u.io, roots, &u.valid, u.inputs, d) catch |e| return mapErr(e, d);
        var paths: std.ArrayList(StorePath) = .empty;
        try paths.appendSlice(arena, w.sources);
        for (w.drvs) |n| try paths.append(arena, n.path);
        if (paths.items.len == 0) {
            st.time = now(u.io) - t0;
            return st;
        }
        st.queried = paths.items.len;
        const valid = try b.queryValid(arena, paths.items, on_event, d);

        const t1 = now(u.io);
        var objects: std.ArrayList(Object) = .empty;
        var substitute: std.ArrayList(StorePath) = .empty;
        for (w.sources) |p| {
            if (valid.contains(p.baseName())) continue;
            if (try u.sourceInfo(arena, p, d)) |info| {
                const o = Object.fromOrigin(arena, u.io, p, info, d) catch |e| {
                    if (e == error.OutOfMemory) return error.OutOfMemory;
                    if (d.msg == null) return remote.failIo(d, e, "cannot dump '{f}'", .{&p});
                    remote.prefix(d, "cannot dump '{f}'", .{&p});
                    return error.Io;
                };
                try objects.append(arena, o);
            } else try substitute.append(arena, p);
        }
        var missing_drvs: usize = 0;
        for (w.drvs) |n| {
            if (!valid.contains(n.path.baseName())) missing_drvs += 1;
        }
        b.noteUpload(.{
            .missing = objects.items.len + substitute.items.len + missing_drvs,
            .resolve_ns = now(u.io) - t1,
            .resolve_paths = objects.items.len,
            // a streamed batch never prints `--timings`
            .store_sources = 0,
        });

        // A path registers only once its references are valid, so the
        // substituted sources must land before the drvs that name them.
        st.substituted = substitute.items.len;
        try b.substitute(substitute.items, on_event, d);

        for (w.drvs) |n| {
            if (valid.contains(n.path.baseName())) continue;
            try objects.append(arena, .drvObject(n.path, n.aterm, n.references));
        }
        const refs = try arena.alloc(*Object, objects.items.len);
        for (objects.items, refs) |*o, *r| r.* = o;
        st.bytes = try b.addObjects(refs, on_event, d);
        st.added = objects.items.len;
        for (w.sources) |p| try u.valid.put(u.gpa, p, {});
        for (w.drvs) |n| try u.valid.put(u.gpa, n.path, {});
        st.time = now(u.io) - t0;
        return st;
    }

    /// A held root prunes the walk at it, as a registered one does.
    pub fn rootsAnswered(u: *StreamUpload, roots: []const StorePath, valid: *const plan.NameSet) Allocator.Error!void {
        for (roots) |r| if (valid.contains(r.baseName())) try u.valid.put(u.gpa, r, {});
    }

    pub fn drvs(u: *StreamUpload, roots: []const StorePath, deep: bool, arena: Allocator, d: *Diag) anyerror![]const Drv {
        if (!deep) {
            const out = try arena.alloc(Drv, roots.len);
            for (roots, out) |*p, *o| {
                const l = try plan.loadDrv(arena, u.io, p, u.inputs, d);
                o.* = .{ .path = p.*, .aterm = l.aterm };
            }
            return out;
        }
        // No pruning: a derivation whose `.drv` the store already has still
        // needs building when its outputs are missing.
        const none: plan.PathSet = .empty;
        const w = try plan.walk(u.gpa, arena, u.io, roots, &none, u.inputs, d);
        const out = try arena.alloc(Drv, w.drvs.len);
        for (w.drvs, out) |n, *o| o.* = .{ .path = n.path, .aterm = n.aterm };
        return out;
    }
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(PlanUpload);
    std.testing.refAllDecls(StreamUpload);
    _ = Uploader.of(PlanUpload, undefined);
    _ = Uploader.of(StreamUpload, undefined);
}
