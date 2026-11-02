//! `iets cache`: `gc` sweeps the cache stores by entry age, `dump` prints
//! the read set of a tracing-cache entry, `paths` the paths a watcher has to
//! watch for its answer to go stale.

const std = @import("std");
const text = @import("../syntax/text.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const cachefs = @import("../cachefs.zig");
const trace = @import("../trace.zig");
const store = trace.store;
const wire = trace.wire;
const watch = trace.watch;
const Log = @import("../log.zig").Log;
const Report = @import("../log.zig").Report;
const Session = @import("../session.zig").Session;
const help = @import("help.zig");

/// The subcommands: the tag is the word.
const Sub = enum { gc, dump, paths };
const subcommands = help.words(Sub);

pub const Ctx = struct {
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    s: *Session,
    log: *Log,
    /// The `cache-dir` setting, under `--cache-dir`.
    cache_dir: ?[]const u8 = null,
};

/// `iets cache ARGS` from the dispatch.
pub fn cmd(cc: *const @import("../cli.zig").Ctx, argv: []const []const u8) u8 {
    const s = cc.s;
    s.log.command = "cache";
    const arena = cc.init.arena.allocator();
    const c: Ctx = .{ .gpa = s.gpa, .arena = arena, .io = cc.init.io, .env = cc.init.environ_map, .s = s, .log = &s.log, .cache_dir = s.settings.cache_dir };
    return main(&c, argv) catch |e| {
        if (e == error.Reported) return 1;
        const r: Report = .{ .code = "cache", .raw = @errorName(e) };
        return r.emit(&s.log);
    };
}

/// `iets cache ARGS...`; the exit code.
pub fn main(c: *const Ctx, args: []const []const u8) !u8 {
    for (args) |a| if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
        try writeOut(c, help.cache);
        return 0;
    };
    if (args.len == 0) return usage(c, "missing subcommand: gc or dump or paths", null);
    const sub = args[0];
    const rest = args[1..];
    const which = std.meta.stringToEnum(Sub, sub) orelse {
        const m = try std.fmt.allocPrint(c.arena, "unknown subcommand '{s}'", .{sub});
        return usage(c, m, try help.suggest(c.arena, sub, &subcommands));
    };
    switch (which) {
        .gc => return gc(c, rest),
        .dump => {
            if (rest.len == 0) return usage(c, "cache dump needs an ENTRY file", null);
            if (rest.len > 1) return unexpected(c, rest[1]);
            return dump(c, rest[0]);
        },
        .paths => {
            if (rest.len == 0) return usage(c, "cache paths needs an ENTRY file", null);
            if (rest.len == 2 and std.mem.eql(u8, rest[1], "--json")) return paths(c, rest[0], true);
            if (rest.len > 1) return unexpected(c, rest[1]);
            return paths(c, rest[0], false);
        },
    }
}

fn unexpected(c: *const Ctx, a: []const u8) !u8 {
    return usage(c, try std.fmt.allocPrint(c.arena, "unexpected argument '{s}'", .{a}), null);
}

/// A bad command line: `error: MSG`, a suggestion, the help pointer; exit 2.
fn usage(c: *const Ctx, msg: []const u8, maybe: ?[]const u8) !u8 {
    return help.usage(c.s, "cache", msg, maybe);
}

/// An `Error::Cache`: `error: MSG`, exit 1.
fn cacheError(c: *const Ctx, msg: []const u8) u8 {
    const r: Report = .{ .code = "cache", .raw = msg };
    return r.emit(c.log);
}

/// `b` on stdout; a failed write is reported, and ends the command.
fn writeOut(c: *const Ctx, b: []const u8) error{Reported}!void {
    c.s.out.writeAll(b) catch {
        _ = help.writeFailed(c.s, b.len);
        return error.Reported;
    };
}

/// `iets cache gc [--ttl DAYS] [--dry-run] [--cache-dir DIR]`. Entries unread
/// for longer than the TTL go; a swept tracing entry misses next time.
fn gc(c: *const Ctx, args: []const []const u8) !u8 {
    var ttl_days: u64 = cachefs.ttl_days;
    var dry_run = false;
    var cache_dir: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const s = args[i];
        if (std.mem.eql(u8, s, "--dry-run") or std.mem.eql(u8, s, "-n")) {
            dry_run = true;
        } else if (std.mem.eql(u8, s, "--ttl")) {
            i += 1;
            if (i >= args.len) return usage(c, "--ttl needs a value", null);
            const v = args[i];
            // a TTL whose seconds do not fit made the window wrap and
            // selected every fresh entry
            const d = std.fmt.parseInt(u64, v, 10) catch null;
            const fits = if (d) |x| (if (std.math.mul(u64, x, cachefs.day_s)) |_| true else |_| false) else false;
            if (!fits) return usage(c, try std.fmt.allocPrint(c.arena, "--ttl wants a number of days, got '{s}'", .{v}), null);
            ttl_days = d.?;
        } else if (std.mem.eql(u8, s, "--cache-dir")) {
            i += 1;
            if (i >= args.len) return usage(c, "--cache-dir needs a value", null);
            cache_dir = args[i];
        } else if (std.mem.startsWith(u8, s, "-")) {
            return usage(c, try std.fmt.allocPrint(c.arena, "unknown flag '{s}'", .{s}), try help.suggest(c.arena, s, help.flagNames("cache")));
        } else return unexpected(c, s);
    }
    const root = (try cachefs.root(c.arena, c.env, cache_dir orelse c.cache_dir)) orelse
        return cacheError(c, "no cache directory (no HOME and no --cache-dir)");
    const stores = try cachefs.stores(c.arena, root);
    // locating the IR cache prepares its store, in Rust iets too
    _ = cachefs.prepareShape(c.io, stores[1].root, .sharded_files, null, false);
    var out: std.Io.Writer.Allocating = .init(c.gpa);
    defer out.deinit();
    for (stores) |st| {
        const s = cachefs.sweep(c.gpa, c.io, st.root, st.shape, ttl_days * cachefs.day_s, dry_run);
        try out.writer.print("{s}: {d} of {d} entries, {d:.1} MiB{s}\n", .{
            st.root,
            s.removed,
            s.scanned,
            @as(f64, @floatFromInt(s.bytes)) / (1024.0 * 1024.0),
            if (dry_run) " (dry run)" else " removed",
        });
    }
    try writeOut(c, out.written());
    return 0;
}

/// The read set of the entry file at `file`, or null when it is not one.
fn readset(c: *const Ctx, file: []const u8) !?struct { entry: store.Entry, obs: []trace.Obs } {
    var e = (try store.Entry.open(c.gpa, c.io, file)) orelse return null;
    const bytes = e.part(.readset) orelse {
        e.deinit(c.gpa);
        return null;
    };
    const obs = (try wire.decodeReadset(c.arena, bytes)) orelse {
        e.deinit(c.gpa);
        return null;
    };
    return .{ .entry = e, .obs = obs };
}

fn notAnEntry(c: *const Ctx, file: []const u8) !u8 {
    return cacheError(c, try std.fmt.allocPrint(c.arena, "{s} is not a cache entry", .{file}));
}

fn hex16(d: *const trace.Digest) [16]u8 {
    return std.fmt.bytesToHex(d[0..8].*, .lower);
}

/// One line per observation of an `entry` file, for debugging misses.
fn dump(c: *const Ctx, file: []const u8) !u8 {
    var rs = (try readset(c, file)) orelse return notAnEntry(c, file);
    defer rs.entry.deinit(c.gpa);
    var out: std.Io.Writer.Allocating = .init(c.gpa);
    defer out.deinit();
    const w = &out.writer;
    const a = c.arena;
    for (rs.obs) |o| switch (o) {
        .file => |x| try w.print("file {s} {d} {s}\n", .{ try text.lossyAlloc(a, x.path), x.size, &hex16(&x.hash) }),
        .dir => |x| try w.print("dir {s} {s}\n", .{ try text.lossyAlloc(a, x.path), &hex16(&x.hash) }),
        .stat => |x| try w.print("stat {s} follow={} {s}\n", .{ try text.lossyAlloc(a, x.path), x.follow, x.kind.debugName() }),
        .tree => |x| {
            try w.print("tree {s} accepted=", .{try text.lossyAlloc(a, x.root)});
            if (x.filtered) |f| try w.print("{d}\n", .{f.accepted.len}) else try w.writeAll("all\n");
        },
        .canon => |x| try w.print("canon {s} -> {s}\n", .{ try text.lossyAlloc(a, x.path), if (x.target) |t| try text.lossyAlloc(a, t) else "(none)" }),
        // the value is a keyed hash; the entry never holds it
        .env => |x| if (x.value) |*v|
            try w.print("env {s} {s}\n", .{ try text.lossyAlloc(a, x.name), &hex16(v) })
        else
            try w.print("env {s} (unset)\n", .{try text.lossyAlloc(a, x.name)}),
        .cmd => |x| try w.print("cmd {s} `{s}` {s}\n", .{ try text.lossyAlloc(a, x.dir), try std.mem.join(a, " ", x.query.argv()), &hex16(&x.hash) }),
        .input => |x| try w.print("input {s} v{d}\n", .{ try text.lossyAlloc(a, x.entry), x.version }),
    };
    try writeOut(c, out.written());
    return 0;
}

/// NUL-separated paths on stdout, or `--json` with the kind of each.
fn paths(c: *const Ctx, file: []const u8, json: bool) !u8 {
    const w = (try watch.ofEntry(c.gpa, c.arena, c.io, file)) orelse return notAnEntry(c, file);
    if (w.len == watch.max) {
        const m = try std.fmt.allocPrint(c.arena, "iets: the answer may depend on more than {d} paths; the first {d} are printed", .{ watch.max, watch.max });
        c.log.textLine(m);
    }
    var out: std.Io.Writer.Allocating = .init(c.gpa);
    defer out.deinit();
    if (json) {
        try out.writer.writeByte('[');
        for (w, 0..) |x, i| {
            if (i > 0) try out.writer.writeByte(',');
            // the keys sorted, as Rust iets writes them
            try out.writer.writeAll("{\"kind\":");
            try text.writeJsonStringRaw(&out.writer, x.kind);
            try out.writer.writeAll(",\"path\":");
            try text.writeJsonStringRaw(&out.writer, x.path);
            try out.writer.writeByte('}');
        }
        try out.writer.writeAll("]\n");
    } else for (w) |x| {
        try out.writer.writeAll(x.path);
        try out.writer.writeByte(0);
    }
    try writeOut(c, out.written());
    return 0;
}

test "a mistyped subcommand or flag is suggested" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("dump", (try help.suggest(a, "dum", &subcommands)).?);
    try std.testing.expect(try help.suggest(a, "--dry", help.flagNames("cache")) == null);
    try std.testing.expectEqualStrings("--json", (try help.suggest(a, "--jsno", help.flagNames("cache"))).?);
}
