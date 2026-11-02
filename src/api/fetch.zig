//! `fetch`: a URL or a fixed-output derivation becomes a hash. The two
//! frontends are `iets plumbing fetch` and `iets prefetch`
//! (docs/reference/plumbing.md, docs/reference/commands.md). Nothing is
//! added to a store.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Diag = @import("../diag.zig").Diag;
const Session = @import("../session.zig").Session;
const Evaluator = @import("../eval/Evaluator.zig");
const log = @import("../log.zig");
const http = @import("../fetch/http.zig");
const spool = @import("../fetch/spool.zig");
const hash_mod = @import("../store/hash.zig");
const Hash = hash_mod.Hash;
const StorePath = @import("../store/path.zig").StorePath;
const drv_mod = @import("../store/drv.zig");
const Derivation = drv_mod.Derivation;
const remote = @import("../remote.zig");
const plan = remote.plan;
const build_mod = @import("../build.zig");
const dispatch = build_mod.dispatch;
const backend = build_mod.backend;
const Provenance = @import("../provenance.zig").Provenance;
const apibuild = @import("build.zig");

/// The flat hash of the bytes `url` serves, or with `unpack` the NAR hash of
/// the tree the archive holds (docs/reference/flakes.md builds the same tree).
pub fn urlHash(s: *Session, url: []const u8, unpack: bool, algo: hash_mod.Algo, d: *Diag) !Hash {
    const ctx: http.Context = .{ .gpa = s.gpa, .io = s.io, .limits = @import("../cli/prefetch.zig").limits(s), .offline = s.settings.offline, .log = &s.log };
    var h: hash_mod.Hasher = .init(algo);
    var hbuf: [64 << 10]u8 = undefined;
    var hw = h.writer(&hbuf);
    if (!unpack) {
        _ = try http.get(ctx, url, &.{}, false, &hw.interface, d);
        hw.interface.flush() catch unreachable;
        return h.finish();
    }
    const file = try spool.scratch(s.io, "prefetch", d);
    var wbuf: [64 << 10]u8 = undefined;
    var fw = file.writer(s.io, &wbuf);
    _ = http.get(ctx, url, &.{}, true, &fw.interface, d) catch |e| {
        file.close(s.io);
        return e;
    };
    fw.interface.flush() catch {
        file.close(s.io);
        return d.fail(error.Io, "cannot write the download: {f}", .{http.ioText(fw.err orelse error.WriteFailed)});
    };
    var tree = try spool.Tree.index(s.gpa, s.io, file, ctx.limits.max_size, d);
    defer tree.deinit();
    tree.dump(&hw.interface, d) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => if (d.msg != null) error.Io else d.fail(error.Io, "cannot hash the unpacked tree: {t}", .{e}),
    };
    hw.interface.flush() catch unreachable;
    return h.finish();
}

/// The hash a fixed-output derivation this run evaluated really produces,
/// and the derivation the answer came from: `root` with a fake hash, built
/// so the mismatch reports the real one. Both in `a`.
pub fn drvHash(ev: *Evaluator, s: *Session, env: ?*const std.process.Environ.Map, a: Allocator, root: StorePath, d: *Diag) !struct { []const u8, StorePath } {
    var evin: apibuild.EvalInputs = .init(ev);
    defer evin.deinit();
    var rw: Rewritten = .{ .inner = evin.inputs() };
    try rw.rewrite(a, root, d);
    return .{ try build(ev, s, env, a, &rw, d), rw.root };
}

/// The evaluation's derivations with one more: `root` rewritten.
const Rewritten = struct {
    inner: plan.Inputs,
    root: StorePath = undefined,
    info: plan.DrvInfo = undefined,
    name: []const u8 = "",

    fn inputs(r: *Rewritten) plan.Inputs {
        return .{ .ctx = r, .drv = drvFn, .source = sourceFn };
    }

    fn drvFn(ctx: ?*anyopaque, p: *const StorePath) ?plan.DrvInfo {
        const r: *Rewritten = @ptrCast(@alignCast(ctx.?));
        if (p.eql(&r.root)) return r.info;
        return r.inner.getDrv(p);
    }

    fn sourceFn(ctx: ?*anyopaque, p: *const StorePath) ?@import("../store/source.zig").SourceOrigin {
        const r: *Rewritten = @ptrCast(@alignCast(ctx.?));
        return r.inner.getSource(p);
    }

    /// `old` with its fixed-output hash replaced by the all-zero hash of the
    /// same algorithm, under the path that rewrite gives it: the output path
    /// follows the hash, and the drv path follows the ATerm. So the build
    /// reports the hash it really produced, and nothing on disk had to
    /// change.
    fn rewrite(r: *Rewritten, a: Allocator, old: StorePath, d: *Diag) !void {
        const info = r.inner.getDrv(&old) orelse return d.fail(error.Usage, "cannot prefetch '{f}': not evaluated", .{&old});
        const aterm = info.aterm orelse return d.fail(error.Usage, "cannot prefetch '{f}': it has no ATerm", .{&old});
        var drv = try Derivation.parse(a, aterm, try Derivation.nameFromPath(&old, d), d);
        // a fixed-output derivation has exactly one output (derivationStrict)
        if (drv.outputs.len == 0 or drv.outputs[0].output != .fixed)
            return d.fail(error.Usage, "cannot prefetch '{f}': not a fixed-output derivation: it has no 'hash'", .{&old});
        const out = &drv.outputs[0];
        const fixed = out.output.fixed;
        const zeros: [64]u8 = @splat(0);
        out.output = .{ .fixed = .{ .method = fixed.method, .hash = .raw(fixed.hash.algo, zeros[0..fixed.hash.algo.size()]) } };
        // only the output path moves: the `outputHash` the builder may read
        // stays what it was, and the daemon checks the output against
        // `outputs`
        const path = try drv.fixedOutputPath(out.name, d);
        try drv.envSet(a, out.name, try std.fmt.allocPrint(a, "{f}", .{&path}));
        const text = try drv.unparseAlloc(a, .{}, d);
        r.root = try drv.drvPathFor(a, text, d);
        r.info = .{ .aterm = text, .references = info.references };
        r.name = drv.name;
    }
};

/// Builds the rewritten root on the builder and answers the hash its
/// output got. The mismatch is the answer, so it is not reported as an
/// error; any other failure is, with the tail the renderer would have
/// shown.
fn build(ev: *Evaluator, s: *Session, env: ?*const std.process.Environ.Map, a: Allocator, rw: *Rewritten, d: *Diag) ![]const u8 {
    const transport = try apibuild.transport(a, s, env, null, d);
    var p = try plan.plan(s.gpa, s.io, &.{rw.root}, rw.inputs(), d);
    var prov = try Provenance.snapshot(s.gpa, ev, s.settings.source_map, &.{}, s.settings.provenance);
    defer prov.deinit();
    const cx: backend.Context = .{ .gpa = s.gpa, .io = s.io, .env = env, .log = .of(&s.log) };
    const b = backend.open(cx, &transport, .default(), .ignore, d) catch |e| {
        p.deinit();
        return e;
    };
    // nothing to watch: the build is meant to fail, and this command's only
    // output is the hash it fails on
    var sink: Io.Writer.Discarding = .init(&.{});
    const quiet = dispatch.Reporter.createOutput(s.gpa, &s.log, .detect(&s.log), &sink.writer, .{}) catch |e| {
        b.close();
        p.deinit();
        return e;
    };
    const dp = dispatch.Dispatcher.withBackend(s.gpa, &s.log, b, &prov, quiet) catch |e| {
        quiet.destroy();
        b.close();
        p.deinit();
        return e;
    };
    var x: apibuild.Dispatch = .{
        .gpa = s.gpa,
        .io = s.io,
        .plan = p,
        .nix = .{ .io = s.io, .env = s.env, .nix_bin_dir = s.settings.nix_bin_dir },
        .d = dp,
    };
    defer x.deinit();
    try s.log.wantMismatch(rw.name);
    const outcomes = try x.submit(&.{.{ .attr = rw.name, .drv = rw.root }}, d);
    const why: []const u8 = if (outcomes.len == 0) "nothing was built" else if (outcomes[0].success) "the fake hash is the hash it produced" else blk: {
        var lines: std.ArrayList([]const u8) = .empty;
        if (outcomes[0].reason) |r| try lines.append(a, r);
        try lines.appendSlice(a, outcomes[0].log_tail);
        break :blk try std.mem.join(a, "\n", lines.items);
    };
    // a remote builder's message comes back as the log of the build, which
    // `wantMismatch` does not see
    const text = try log.stripAnsi(a, why);
    const taken = try s.log.takeMismatches();
    defer s.log.freePairs(taken);
    const drv_suffix = try std.fmt.allocPrint(a, "-{s}.drv", .{rw.name});
    const got: []const u8 = if (taken.len > 0)
        try a.dupe(u8, taken[0].got)
    else if (log.mismatch(text)) |m| (if (std.mem.indexOf(u8, text, drv_suffix) != null) m.got else return d.fail(error.Store, "cannot prefetch '{s}': {s}", .{ rw.name, why })) else return d.fail(error.Store, "cannot prefetch '{s}': {s}", .{ rw.name, why });
    var hd: Diag = .init(a);
    const h = Hash.parseAny(got, null, &hd) catch return got;
    return h.alloc(a, .sri, true);
}

const testing = std.testing;

const real = "sha256-0M0pRasuDjQWaa/XKanIMFJQdq43r1N8bGujzW7BndU=";

/// A one-output derivation, and the inputs an evaluation leaves.
const Table = struct {
    root: StorePath,
    info: plan.DrvInfo,

    fn of(a: Allocator, out: drv_mod.Output, d: *Diag) !Table {
        var outputs = [_]drv_mod.NamedOutput{.{ .name = "out", .output = out }};
        var drv: Derivation = .{ .name = "msg", .outputs = &outputs, .platform = "x86_64-linux", .builder = "/bin/sh" };
        if (drv.fixedOutputPath("out", d)) |p| try drv.envSet(a, "out", try std.fmt.allocPrint(a, "{f}", .{&p})) else |_| {}
        try drv.envSet(a, "outputHash", real);
        const text = try drv.unparseAlloc(a, .{}, d);
        return .{ .root = try drv.drvPathFor(a, text, d), .info = .{ .aterm = text, .references = &.{} } };
    }

    fn inputs(t: *Table) plan.Inputs {
        return .{ .ctx = t, .drv = struct {
            fn f(ctx: ?*anyopaque, p: *const StorePath) ?plan.DrvInfo {
                const tt: *Table = @ptrCast(@alignCast(ctx.?));
                return if (p.eql(&tt.root)) tt.info else null;
            }
        }.f };
    }
};

test "the fake hash moves the output and the drv" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .init(a);
    var t = try Table.of(a, .{ .fixed = .{ .method = .flat, .hash = try Hash.parseAny(real, null, &d) } }, &d);
    var rw: Rewritten = .{ .inner = t.inputs() };
    try rw.rewrite(a, t.root, &d);
    try testing.expectEqualStrings("msg", rw.name);
    try testing.expect(!rw.root.eql(&t.root));
    const drv = try Derivation.parse(a, rw.info.aterm.?, "msg", &d);
    try testing.expect((try drv.drvPath(a, &d)).eql(&rw.root));
    try testing.expectEqualStrings(real, drv.envGet("outputHash").?);
    const out = try drv.fixedOutputPath("out", &d);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{f}", .{&out}), drv.envGet("out").?);
    try testing.expectEqualStrings("sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", try drv.outputs[0].output.fixed.hash.alloc(a, .sri, true));
    // the derivation the evaluation made is still there, untouched
    const old = try Derivation.parse(a, t.info.aterm.?, "msg", &d);
    try testing.expect(!std.mem.eql(u8, old.envGet("out").?, drv.envGet("out").?));
    // and the inputs answer both
    try testing.expect(rw.inputs().getDrv(&t.root) != null);
    try testing.expect(rw.inputs().getDrv(&rw.root) != null);
}

test "only a fixed-output drv can be prefetched" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .init(a);
    var t = try Table.of(a, .{ .input_addressed = try StorePath.parse("/nix/store/00000000000000000000000000000000-msg", &d) }, &d);
    var rw: Rewritten = .{ .inner = t.inputs() };
    try testing.expectError(error.Usage, rw.rewrite(a, t.root, &d));
    try testing.expect(std.mem.indexOf(u8, d.message(), "not a fixed-output derivation") != null);
}
