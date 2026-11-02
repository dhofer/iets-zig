//! A made-up SCM that only the tests know. Its shape is not the shape of
//! git, so a part of the interface that only git can fill fails here: the
//! marker is the directory `.ledger`, `tracked` lists the files as text,
//! `head` holds `r<count> <date>` and is absent before the first revision,
//! the entry `dirty` is the dirty flag, a revision always has a count, and
//! no answer comes from a command. `refs` holds `<name> <rev>` lines, and
//! `revs/<rev>` holds the date of a revision, then one `<path>=<text>` line
//! for each of its files.

const std = @import("std");
const Io = std.Io;
const scm_mod = @import("../scm.zig");
const Cx = scm_mod.Cx;
const Error = scm_mod.Error;
const PathSet = @import("../../builtins/store_hooks.zig").PathSet;

pub const scm: scm_mod.Scm = .{
    .name = "ledger",
    .title = "Ledger",
    .marker = ".ledger",
    .snapshot = snapshot,
    .rev_count = revCount,
    .resolve = resolve,
    .tree_at = treeAt,
    .untracked = untracked,
    .tree_of = treeOf,
    .watch = watch,
};

const trace_mod = @import("../../trace.zig");

const ledger_files = [_][]const u8{ "/.ledger/tracked", "/.ledger/head", "/.ledger/dirty" };

/// The root of the tree a ledger file observation is about.
fn treeOf(o: trace_mod.Obs) ?[]const u8 {
    const path = switch (o) {
        .file => |x| x.path,
        .stat => |x| x.path,
        else => return null,
    };
    for (ledger_files) |e| if (std.mem.endsWith(u8, path, e)) return path[0 .. path.len - e.len];
    return null;
}

fn read(cx: Cx, p: []const u8) Error![]const u8 {
    const f = scm_mod.readFileMeta(cx.io, cx.a, p) orelse
        return cx.d.fail(error.ScmFailed, "ledger: {s}: cannot read it", .{p});
    cx.trace.file(p, f.meta, f.bytes);
    return f.bytes;
}

fn there(cx: Cx, p: []const u8) bool {
    return cx.trace.statNow(p, false) != .missing;
}

fn snapshot(cx: Cx, root: []const u8) Error!scm_mod.Snapshot {
    const dot = try scm_mod.join(cx.a, root, ".ledger");
    const tracked = try read(cx, try scm_mod.join(cx.a, dot, "tracked"));
    const head_p = try scm_mod.join(cx.a, dot, "head");
    const head: ?[]const u8 = if (there(cx, head_p)) try read(cx, head_p) else null;
    var rev: ?[]const u8 = null;
    var date: u64 = 0;
    if (head) |h| {
        const t = std.mem.trim(u8, h, " \t\r\n");
        if (std.mem.indexOfScalar(u8, t, ' ')) |i| {
            rev = t[0..i];
            date = std.fmt.parseInt(u64, t[i + 1 ..], 10) catch 0;
        }
    }
    var files: PathSet = .empty;
    var lines = std.mem.splitScalar(u8, tracked, '\n');
    while (lines.next()) |l| if (l.len > 0) try files.put(cx.a, try scm_mod.join(cx.a, root, l), {});
    return .{
        .files = files,
        .dirty = there(cx, try scm_mod.join(cx.a, dot, "dirty")),
        .rev = rev,
        .last_modified = date,
        .countable = true,
    };
}

fn revCount(cx: Cx, _: []const u8, rev: []const u8) Error!u64 {
    if (std.mem.startsWith(u8, rev, "r")) if (std.fmt.parseInt(u64, rev[1..], 10)) |n| return n else |_| {};
    return cx.d.fail(error.ScmFailed, "ledger: '{s}' is no revision", .{rev});
}

fn resolve(cx: Cx, root: []const u8, name: []const u8) Error!?[]const u8 {
    const refs_p = try scm_mod.join(cx.a, root, ".ledger/refs");
    if (!there(cx, refs_p)) return null;
    const refs = try read(cx, refs_p);
    var lines = std.mem.splitScalar(u8, refs, '\n');
    while (lines.next()) |l| {
        if (std.mem.startsWith(u8, l, name) and l.len > name.len and l[name.len] == ' ') return l[name.len + 1 ..];
    }
    return null;
}

/// A revision's text follows from its name, so it is no observation.
fn treeAt(cx: Cx, root: []const u8, rev: []const u8, _: bool) Error!?scm_mod.Commit {
    const p = try std.fmt.allocPrint(cx.a, "{s}/.ledger/revs/{s}", .{ root, rev });
    const text = Io.Dir.cwd().readFileAlloc(cx.io, p, cx.a, .unlimited) catch return null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    const date = std.fmt.parseInt(u64, lines.next() orelse "", 10) catch
        return cx.d.fail(error.ScmFailed, "ledger: '{s}' has no date", .{rev});
    var entries: std.ArrayList(scm_mod.PathEntry) = .empty;
    while (lines.next()) |l| {
        const eq = std.mem.indexOfScalar(u8, l, '=') orelse continue;
        const bytes = try std.mem.concat(cx.a, u8, &.{ l[eq + 1 ..], "\n" });
        try entries.append(cx.a, .{ .path = l[0..eq], .entry = .{ .file = .{ .bytes = bytes, .exec = false } } });
    }
    return .{ .rev = rev, .last_modified = date, .entries = entries.items };
}

fn untracked(cx: Cx, root: []const u8, rel: []const u8) ?[]const u8 {
    const p = scm_mod.join(cx.a, root, ".ledger/tracked") catch return null;
    const tracked = Io.Dir.cwd().readFileAlloc(cx.io, p, cx.a, .unlimited) catch return null;
    var lines = std.mem.splitScalar(u8, tracked, '\n');
    while (lines.next()) |l| if (std.mem.eql(u8, l, rel)) return null;
    return std.fmt.allocPrint(cx.a, "ledger track \"{s}/{s}\"", .{ root, rel }) catch null;
}

fn watch(_: std.mem.Allocator, _: Io, _: []const u8) std.mem.Allocator.Error!?[]const u8 {
    return null;
}

const testing = std.testing;
const Evaluator = @import("../../eval/Evaluator.zig");
const value = @import("../../runtime/value.zig");
const Diag = @import("../../diag.zig").Diag;
const source = @import("../../source.zig");
const flake = @import("../../flake.zig");
const nar = @import("../../store/nar.zig");

const flake_text = "{ outputs = _: { }; }\n";

/// A working tree with three tracked files, one untracked file and the
/// revision `r12`; `plain` holds the tracked files and nothing else. The
/// directory is under /tmp: the repository the tests run in is a git
/// working tree, which `plain` must not be inside.
const Fixture = struct {
    base: []u8,
    root: []u8,
    plain: []u8,
    arena: std.heap.ArenaAllocator,
    interner: @import("../../syntax/symbol.zig").Interner,
    files: @import("../../eval/Files.zig"),
    shared: Evaluator.Shared = .{},
    local: Evaluator.Local,
    store: @import("../../treestore.zig").Store,
    ev: Evaluator,

    fn init(f: *Fixture) !void {
        const gpa = testing.allocator;
        const io = testing.io;
        var r: [8]u8 = undefined;
        @import("../../sys.zig").random(&r);
        f.base = try std.fmt.allocPrint(gpa, "/tmp/iets-ledger-{x}", .{r});
        f.root = try std.fmt.allocPrint(gpa, "{s}/tree", .{f.base});
        f.plain = try std.fmt.allocPrint(gpa, "{s}/plain", .{f.base});
        for ([_][]const u8{ f.root, f.plain }) |top| {
            for ([_][]const u8{ "flake.nix", "sub/flake.nix", "sub/lib.nix" }) |name| try f.write(top, name, flake_text);
        }
        try f.write(f.root, "extra", "not tracked\n");
        try f.write(f.root, ".ledger/tracked", "flake.nix\nsub/flake.nix\nsub/lib.nix\n");
        try f.write(f.root, ".ledger/head", "r12 1700000000\n");
        f.arena = .init(gpa);
        f.interner = try .init(gpa);
        f.files = .init(gpa, io);
        f.shared = .{};
        f.local = .init(gpa);
        value.flat_arena = &f.local.arena;
        f.store = .init(gpa, io, try std.fmt.allocPrint(f.arena.allocator(), "{s}/cache/inputs", .{f.base}));
        f.ev = try .init(gpa, io, &f.local, &f.interner, &f.files, &f.shared, .{ .inputs = &f.store });
        try @import("../../builtins.zig").install(&f.ev);
    }

    fn deinit(f: *Fixture) void {
        const gpa = testing.allocator;
        f.ev.deinit();
        f.store.deinit();
        value.flat_arena = null;
        f.local.deinit();
        f.shared.deinit(gpa);
        f.files.deinit();
        f.interner.deinit();
        f.arena.deinit();
        Io.Dir.cwd().deleteTree(testing.io, f.base) catch {};
        gpa.free(f.root);
        gpa.free(f.plain);
        gpa.free(f.base);
    }

    fn write(_: *Fixture, top: []const u8, rel: []const u8, data: []const u8) !void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const p = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ top, rel });
        if (std.fs.path.dirname(p)) |d| try Io.Dir.cwd().createDirPath(testing.io, d);
        try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = p, .data = data });
    }

    fn ref(f: *Fixture, arg: []const u8) !flake.FlakeRef {
        var d: Diag = .init(f.arena.allocator());
        return flake.parseFlakeRef(f.arena.allocator(), testing.io, arg, "/", null, &d);
    }

    fn readTree(f: *Fixture) !source.Tree {
        const r = try f.ref(try std.fmt.allocPrint(f.arena.allocator(), "{s}/sub#x", .{f.root}));
        return source.tree(&f.ev, &r.source, .none);
    }

    fn narHash(f: *Fixture, dir: []const u8) ![]const u8 {
        var d: Diag = .init(testing.allocator);
        defer d.deinit();
        const h = try nar.narHash(testing.allocator, testing.io, Io.Dir.cwd(), dir, &d);
        return h.alloc(f.arena.allocator(), .sri, true);
    }

    /// The attributes a ledger tree has: `pairs`, its type, url and hash.
    fn expectAttrs(f: *Fixture, got: *const source.Attrs, pairs: []const source.Attrs.Entry) !void {
        const a = f.arena.allocator();
        var want: source.Attrs = .{};
        for (pairs) |p| try want.put(a, p.key, p.value);
        try want.put(a, "type", .{ .str = "ledger" });
        try want.put(a, "url", .{ .str = try std.fmt.allocPrint(a, "file://{s}", .{f.root}) });
        try want.put(a, "narHash", .{ .str = try f.narHash(f.plain) });
        try testing.expectEqual(want.len(), got.len());
        for (want.items(), got.items()) |w, g| {
            try testing.expectEqualStrings(w.key, g.key);
            if (!w.value.eql(g.value)) {
                std.debug.print("{s}: want {any}, got {any}\n", .{ w.key, w.value, g.value });
                return error.TestExpectedEqual;
            }
        }
    }
};

test "a directory in a working tree is found" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var r = try f.ref(try std.fmt.allocPrint(a, "{s}/sub#x", .{f.root}));
    try testing.expect(r.source.eql(&.{ .tracked = .{ .scm = &scm, .root = f.root, .subdir = "sub" } }));
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "ledger+file://{s}?dir=sub", .{f.root}), try flake.refUrl(a, &r));
    r = try f.ref(f.root);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "ledger+file://{s}", .{f.root}), try flake.refUrl(a, &r));
    r = try f.ref(try std.fmt.allocPrint(a, "path:{s}/sub", .{f.root}));
    try testing.expect(r.source.eql(&.{ .path = try std.fmt.allocPrint(a, "{s}/sub", .{f.root}) }));
}

test "the tracked files and the metadata are the tree" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var t = try f.readTree();
    try testing.expectEqualStrings("sub", t.subdir);
    try f.expectAttrs(&t.attrs, &.{ .{ .key = "rev", .value = .{ .str = "r12" } }, .{ .key = "lastModified", .value = .{ .int = 1700000000 } } });
    try testing.expect(t.counter.?.scm == &scm and std.mem.eql(u8, t.counter.?.root, f.root));

    try f.write(f.root, ".ledger/dirty", "");
    for ([_][]const u8{ f.root, f.plain }) |top| try f.write(top, "sub/lib.nix", "1\n");
    t = try f.readTree();
    try f.expectAttrs(&t.attrs, &.{
        .{ .key = "dirtyRev", .value = .{ .str = "r12-dirty" } },
        .{ .key = "dirtyShortRev", .value = .{ .str = "r12-dirty" } },
        .{ .key = "lastModified", .value = .{ .int = 1700000000 } },
    });
    try testing.expect(t.counter == null);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try Io.Dir.cwd().deleteFile(testing.io, try std.fmt.bufPrint(&buf, "{s}/.ledger/dirty", .{f.root}));
    try Io.Dir.cwd().deleteFile(testing.io, try std.fmt.bufPrint(&buf, "{s}/.ledger/head", .{f.root}));
    t = try f.readTree();
    try f.expectAttrs(&t.attrs, &.{.{ .key = "lastModified", .value = .{ .int = 0 } }});
    try testing.expect(t.counter == null);
}

test "the metadata has the mark of its tree, and the count is lazy" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const t = try f.readTree();
    const fetch = @import("../../builtins/fetch.zig");
    const import_ = @import("../../eval/import.zig");
    const info = try fetch.emitTreeAttrs(&f.ev, &t, "self", .none);
    for ([_][3][]const u8{
        .{ "t: t.rev", "r12", "self.rev" },
        .{ "t: t.shortRev", "r12", "self.shortRev" },
        .{ "t: t.lastModifiedDate", "20231114221320", "self.lastModifiedDate" },
    }) |c| {
        const fv = try import_.evalString(&f.ev, c[0]);
        const s = try f.ev.forceString(try f.ev.apply(fv, &.{info}, .none), .none, "");
        try testing.expectEqualStrings(c[1], s.bytes());
        try testing.expectEqual(@as(usize, 1), s.context().len);
        try testing.expectEqual(value.CtxKind.impure_meta, s.context()[0].kind);
        try testing.expectEqualStrings(c[2], s.context()[0].path);
    }
    const fv = try import_.evalString(&f.ev, "t: t.revCount + t.lastModified");
    const v = try f.ev.force(try f.ev.apply(fv, &.{info}, .none));
    try testing.expectEqual(@as(i64, 1700000012), v.view().int);

    // `x12` is a revision that the ledger cannot count, so a count of it
    // shows where the answer comes from
    try f.write(f.root, ".ledger/head", "x12 1700000000\n");
    const t2 = try f.readTree();
    const info2 = try fetch.emitTreeAttrs(&f.ev, &t2, "self", .none);
    const has = try import_.evalString(&f.ev, "t: t ? revCount && builtins.elem \"revCount\" (builtins.attrNames t)");
    try testing.expectEqual(Value.true, try f.ev.force(try f.ev.apply(has, &.{info2}, .none)));
    const count = try import_.evalString(&f.ev, "t: t.revCount");
    const failed = if (f.ev.apply(count, &.{info2}, .none)) |r| f.ev.force(r) else |e| e;
    try testing.expectError(error.EvalFailed, failed);
    try testing.expectEqualStrings("ledger: 'x12' is no revision", f.ev.failure.?.msg);

    // the run's store keeps a count by revision, and a kept count answers
    const gpa = testing.allocator;
    const a = f.arena.allocator();
    var st = try trace_mod.store.Store.locate(gpa, testing.io, try std.fmt.allocPrint(a, "{s}/cache", .{f.base}));
    defer st.deinit();
    try testing.expect(@import("../../cachefs.zig").prepareShape(testing.io, st.root, .dirs, null, false));
    var rec: trace_mod.Recorder = .init(gpa, testing.io, &st);
    defer rec.deinit();
    f.ev.config.trace = rec.handle();
    defer f.ev.config.trace = .off;
    rec.handle().keep(try scm_mod.countKey(a, &scm, "x12"), "7");
    const t3 = try f.readTree();
    const info3 = try fetch.emitTreeAttrs(&f.ev, &t3, "self", .none);
    try testing.expectEqual(@as(i64, 7), (try f.ev.force(try f.ev.apply(count, &.{info3}, .none))).view().int);
    var d: @import("../../diag.zig").Diag = .init(gpa);
    defer d.deinit();
    const cx: Cx = .{ .gpa = gpa, .io = testing.io, .a = a, .trace = rec.handle(), .d = &d };
    try testing.expectEqual(@as(u64, 12), try scm_mod.revCount(cx, &scm, f.root, "r12"));
    try testing.expectEqualStrings("12", rec.handle().kept(a, try scm_mod.countKey(a, &scm, "r12")).?);
    var off = cx;
    off.trace = .off;
    try testing.expectEqual(@as(u64, 13), try scm_mod.revCount(off, &scm, f.root, "r13"));
}

const Value = value.Value;

test "a name resolves to a revision and a revision has a tree" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.write(f.root, ".ledger/refs", "main r12\nv1 r3\n");
    try f.write(f.root, ".ledger/revs/r3", "1600000000\na=1\nsub/b=2\n");
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const cx = source.scmCx(&f.ev, &d);
    try testing.expectEqualStrings("r3", (try resolve(cx, f.root, "v1")).?);
    try testing.expectEqualStrings("r12", (try resolve(cx, f.root, "main")).?);
    try testing.expect(try resolve(cx, f.root, "v") == null);
    try testing.expect(try treeAt(cx, f.root, "r12", true) == null);
    const c = (try treeAt(cx, f.root, "r3", true)).?;
    try testing.expectEqualStrings("r3", c.rev);
    try testing.expectEqual(@as(u64, 1600000000), c.last_modified);
    try testing.expectEqual(@as(usize, 2), c.entries.len);
    try testing.expectEqualStrings("a", c.entries[0].path);
    try testing.expectEqualStrings("1\n", c.entries[0].entry.file.bytes);
    try testing.expectEqualStrings("sub/b", c.entries[1].path);
    try testing.expectEqualStrings("2\n", c.entries[1].entry.file.bytes);
}

test "an untracked file is the error of nix" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const t = try f.readTree();
    const a = f.arena.allocator();
    var buf: [512]u8 = undefined;
    const store = t.path.print(&buf);
    const hooks = @import("../../builtins/store_hooks.zig");
    _ = try hooks.open(&f.ev, try std.fmt.allocPrint(a, "{s}/sub/lib.nix", .{store}), .none);
    try testing.expectError(error.EvalFailed, hooks.open(&f.ev, try std.fmt.allocPrint(a, "{s}/extra", .{store}), .none));
    const add = try std.fmt.allocPrint(a, "ledger track \"{s}/extra\"", .{f.root});
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "Path 'extra' in the repository \"{s}\" is not tracked by Ledger.\n\nTo make it visible to Nix, run:\n\n{s}", .{ f.root, add }), f.ev.failure.?.msg);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "run '{s}'", .{add}), f.ev.failure.?.hint.?);
}

test "a change of the ledger is a change of the working tree" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var rec: trace_mod.Recorder = .init(testing.allocator, testing.io, null);
    defer rec.deinit();
    f.ev.config.trace = rec.handle();
    _ = try f.readTree();
    const a = f.arena.allocator();
    const obs = try rec.handle().take(a);
    var kinds: std.ArrayList([]const u8) = .empty;
    for (obs) |o| try kinds.append(a, @tagName(std.meta.activeTag(o)));
    const want = [_][]const u8{ "file", "stat", "file", "stat", "tree" };
    try testing.expectEqual(want.len, kinds.items.len);
    for (want, kinds.items) |w, g| try testing.expectEqualStrings(w, g);
    // each observation of the ledger names its working tree, and its change
    // is one of that tree
    const why = scm_mod.changed(a, obs[0]).?;
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "the ledger working tree in {s} changed", .{f.root}), why);
    try testing.expect(scm_mod.owner(obs[4]) == null);
    const watched = try trace_mod.watch.watched(a, testing.io, obs, &.{});
    var paths: std.ArrayList([]const u8) = .empty;
    for (watched) |w| try paths.append(a, w.path);
    try testing.expectEqual(@as(usize, 3), paths.items.len);
    for (ledger_files, paths.items) |e, p| try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}{s}", .{ f.root, e }), p);
}
