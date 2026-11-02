//! The plumbing/porcelain boundary, checked
//! (docs/explanation/plumbing-and-porcelain.md), as Rust iets's
//! tests/layering.rs checks it.
//!
//! `src/cli` is porcelain. A capability is implemented once, below the
//! command line, and a command reaches it through `api.zig`. What this test
//! bans is a second implementation of something the operation layer owns:
//! a file under `src/cli` that imports a layer below the api.
//!
//! The two lists below are today's gaps, each one's length locked by a
//! constant: an entry that goes cannot come back unnoticed, and a new entry
//! needs the constant raised, which is a line in a diff to argue about.
//! Rust iets's lists are the goal; an entry here that differs from Rust
//! iets's is marked.

const std = @import("std");
const testing = std.testing;

/// The layers a porcelain command may not import, by the paths under
/// `src/` that are each layer. `eval` is `src/eval/` but the scheduler,
/// which is `parallel` as in Rust.
const Layer = struct { name: []const u8, paths: []const []const u8 };
const layers = [_]Layer{
    .{ .name = "build", .paths = &.{ "build.zig", "build/" } },
    .{ .name = "compile", .paths = &.{"compile.zig"} },
    .{ .name = "devenv", .paths = &.{ "devenv.zig", "devenv/" } },
    .{ .name = "eval", .paths = &.{ "eval.zig", "eval/" } },
    .{ .name = "flake", .paths = &.{ "flake.zig", "flake/" } },
    .{ .name = "jobs", .paths = &.{ "jobs.zig", "jobs/" } },
    .{ .name = "parallel", .paths = &.{ "eval/Pool.zig", "eval/Deque.zig" } },
    .{ .name = "remote", .paths = &.{ "remote.zig", "remote/" } },
    .{ .name = "store", .paths = &.{ "store.zig", "store/" } },
    .{ .name = "trace", .paths = &.{ "trace.zig", "trace/" } },
};

/// Files under `src/cli` that still import a layer below the api, with the
/// layers each one imports, sorted. This list may only shrink.
const reaches = [_]struct { []const u8, []const []const u8 }{
    .{ "build.zig", &.{ "build", "eval", "remote", "store", "trace" } },
    .{ "cache.zig", &.{"trace"} },
    .{ "classic/build.zig", &.{ "build", "eval", "remote", "store" } },
    .{ "classic/develop.zig", &.{"devenv"} },
    // Rust: eval only
    .{ "classic/drvshow.zig", &.{ "eval", "store" } },
    // Rust: eval only
    .{ "classic/fmt.zig", &.{ "eval", "remote", "store" } },
    // Rust: build, eval, remote
    .{ "classic/instantiate.zig", &.{ "eval", "remote", "store" } },
    // Rust: eval, remote
    .{ "classic/mod.zig", &.{ "eval", "remote", "trace" } },
    // Rust: no trace
    .{ "classic/nix.zig", &.{ "build", "eval", "remote", "store", "trace" } },
    // Rust: compile too
    .{ "classic/shell.zig", &.{ "build", "devenv", "eval", "remote", "store" } },
    // Rust: build, trace too
    .{ "devenv.zig", &.{ "devenv", "eval", "remote", "store" } },
    // Rust's devenv.rs has these; the hooks are a file of their own here
    .{ "devenv_hooks.zig", &.{ "build", "devenv", "eval", "remote", "store" } },
    // Rust: remote, store
    .{ "diff.zig", &.{ "eval", "remote", "store" } },
    // Rust: trace too
    .{ "eval.zig", &.{"eval"} },
    // Rust: none (prefetch.rs is the `--json` choice over plumbing's fetch;
    // the source port's prefetch.zig computes the hash itself)
    .{ "prefetch.zig", &.{ "eval", "store" } },
    // Rust: no build, store
    .{ "jobs.zig", &.{ "build", "eval", "jobs", "remote", "store" } },
    .{ "plumbing.zig", &.{ "build", "eval", "jobs", "remote", "store" } },
    // Rust: none. `api.initStoreDir` is the same code, but called from here
    // it moved the evaluator's hot code and cost 1.5% at one worker
    // (branch aliasing: the same instruction count, 3% more branch misses).
    .{ "run.zig", &.{"store"} },
    // Rust: parallel, trace too (Zig's walk names the task kind through
    // the evaluator)
    .{ "search.zig", &.{"eval"} },
};

/// Locked, so `reaches` can only shrink. Lower it when an entry goes.
const reaches_len = 19;

/// Files under `src/cli` with `Value`, an evaluator value, in a function
/// signature. A command that cannot name a value cannot evaluate one. This
/// list may only shrink.
const value_in_signatures = [_][]const u8{
    "classic/instantiate.zig",
    "classic/mod.zig",
    "classic/nix.zig",
    "classic/shell.zig",
    // Rust: the value is the closure's argument, which names no type
    "eval.zig",
    "jobs.zig",
    "search.zig",
};

/// Locked, so `value_in_signatures` can only shrink.
const value_len = 7;

const rule =
    \\docs/explanation/plumbing-and-porcelain.md: a capability is implemented once, below the command line.
    \\Either the operation layer is missing something (add it to api.zig and
    \\call that from here) or this is presentation, compatibility or interaction,
    \\in which case it belongs in a porcelain-side library that imports no layer.
;

const File = struct { rel: []const u8, text: []const u8 };

/// Every `.zig` file under src/cli, its comment lines dropped: a doc
/// comment that names a layer is not a reach.
fn cliFiles(a: std.mem.Allocator) ![]File {
    const io = testing.io;
    const src = @import("build_options").src_dir;
    var dir = try std.Io.Dir.cwd().openDir(io, src, .{});
    defer dir.close(io);
    var cli_dir = try dir.openDir(io, "cli", .{ .iterate = true });
    defer cli_dir.close(io);
    var walk = try cli_dir.walk(a);
    defer walk.deinit();
    var out: std.ArrayList(File) = .empty;
    while (try walk.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.path, ".zig")) continue;
        const raw = try cli_dir.readFileAlloc(io, e.path, a, .unlimited);
        var text: std.ArrayList(u8) = .empty;
        var it = std.mem.splitScalar(u8, raw, '\n');
        while (it.next()) |l| {
            if (std.mem.startsWith(u8, std.mem.trimStart(u8, l, " \t"), "//")) continue;
            try text.appendSlice(a, l);
            try text.append(a, '\n');
        }
        try out.append(a, .{ .rel = try a.dupe(u8, e.path), .text = text.items });
    }
    std.mem.sort(File, out.items, {}, struct {
        fn lt(_: void, x: File, y: File) bool {
            return std.mem.lessThan(u8, x.rel, y.rel);
        }
    }.lt);
    return out.items;
}

/// The layers `f` imports: an `@import` of a path that, resolved against
/// the file's directory, lies in the layer.
fn imported(a: std.mem.Allocator, f: File) ![]const []const u8 {
    var named: std.ArrayList([]const u8) = .empty;
    const dir = std.fs.path.dirname(f.rel) orelse "";
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, f.text, at, "@import(\"")) |i| {
        const start = i + "@import(\"".len;
        const end = std.mem.indexOfScalarPos(u8, f.text, start, '"') orelse break;
        at = end;
        const target = f.text[start..end];
        if (!std.mem.endsWith(u8, target, ".zig")) continue;
        // the path under src/
        const full = try std.fs.path.resolvePosix(a, &.{ "/cli", dir, target });
        const under = full[1..];
        for (layers) |l| {
            const hit = for (l.paths) |p| {
                if (std.mem.endsWith(u8, p, "/") and std.mem.startsWith(u8, under, p)) break true;
                if (std.mem.eql(u8, under, p)) break true;
            } else false;
            // the scheduler is not `eval`
            const sched = std.mem.eql(u8, l.name, "eval") and (std.mem.eql(u8, under, "eval/Pool.zig") or std.mem.eql(u8, under, "eval/Deque.zig"));
            if (!hit or sched) continue;
            for (named.items) |n| {
                if (std.mem.eql(u8, n, l.name)) break;
            } else try named.append(a, l.name);
        }
    }
    std.mem.sort([]const u8, named.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return named.items;
}

fn has(set: []const []const u8, x: []const u8) bool {
    for (set) |y| if (std.mem.eql(u8, x, y)) return true;
    return false;
}

test "porcelain imports no layer below the api" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = try cliFiles(a);
    var found: std.ArrayList(struct { []const u8, []const []const u8 }) = .empty;
    for (files) |f| {
        const named = try imported(a, f);
        if (named.len > 0) try found.append(a, .{ f.rel, named });
    }
    var ok = true;
    for (found.items) |e| {
        const allowed = for (reaches) |r| {
            if (std.mem.eql(u8, r[0], e[0])) break r[1];
        } else null;
        for (e[1]) |l| if (allowed == null or !has(allowed.?, l)) {
            std.debug.print("src/cli/{s} imports {s}, which is below api.zig and not on its allow-list.\n\n{s}\n\n", .{ e[0], l, rule });
            ok = false;
        };
    }
    // the entries that no longer need to be there
    for (reaches) |r| {
        const named = for (found.items) |e| {
            if (std.mem.eql(u8, e[0], r[0])) break e[1];
        } else &[_][]const u8{};
        for (r[1]) |l| if (!has(named, l)) {
            std.debug.print("src/cli/layering.zig: the allow-list is wider than the code needs: {s}: {s}. Delete it, and lower reaches_len if a whole entry went.\n", .{ r[0], l });
            ok = false;
        };
    }
    try testing.expect(ok);
    try testing.expectEqual(reaches_len, reaches.len);
}

/// Every `fn` declaration's signature: from `fn` to the body or the `;`.
fn hasValueInSignature(text: []const u8) bool {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, text, at, "fn ")) |start| {
        at = start + 3;
        if (start > 0 and isWord(text[start - 1])) continue;
        const end = std.mem.indexOfAnyPos(u8, text, start, "{;") orelse text.len;
        if (hasWord(text[start..end], "Value")) return true;
        at = end;
    }
    return false;
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// `ident` as a whole word, not a field or a longer name (`api.value.Value`
/// is the facade's view, not the evaluator's).
fn hasWord(text: []const u8, ident: []const u8) bool {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, text, at, ident)) |s| {
        const e = s + ident.len;
        at = e;
        const before = s == 0 or !(isWord(text[s - 1]) or text[s - 1] == '.');
        const after = e >= text.len or !isWord(text[e]);
        if (before and after) return true;
    }
    return false;
}

test "porcelain signatures name no evaluator value" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const files = try cliFiles(arena.allocator());
    var ok = true;
    var n: usize = 0;
    for (files) |f| {
        if (!hasValueInSignature(f.text)) continue;
        n += 1;
        if (!has(&value_in_signatures, f.rel)) {
            std.debug.print("src/cli/{s} has an evaluator Value in a function signature.\nA porcelain command that cannot name an evaluator value cannot evaluate one: take the value through api.zig.\n", .{f.rel});
            ok = false;
        }
    }
    if (n != value_in_signatures.len) {
        std.debug.print("src/cli/layering.zig: value_in_signatures lists {d} files, {d} have a Value in a signature; delete the stale ones and lower value_len.\n", .{ value_in_signatures.len, n });
        ok = false;
    }
    try testing.expect(ok);
    try testing.expectEqual(value_len, value_in_signatures.len);
}
