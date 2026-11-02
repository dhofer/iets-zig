//! The `fix-hashes` setting (docs/reference/settings.md): a fixed-output build that
//! failed on its hash gets the hash it produced written over the one it
//! specified, in the one local file evaluation read that holds it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Diag = @import("../diag.zig").Diag;
const Log = @import("../log.zig").Log;
const errors = @import("../errors.zig");
const hash_mod = @import("../store/hash.zig");
const Hash = hash_mod.Hash;
const path_mod = @import("../store/path.zig");
const provenance = @import("../provenance.zig");
const Evaluator = @import("../eval/Evaluator.zig");
const Pair = @import("../config.zig").Override;
const sys = @import("../sys.zig");

/// One rewrite: `old` becomes `new` at byte `at` of `file`, which is
/// `line:column`.
pub const Fix = struct {
    file: []const u8,
    at: usize,
    line: usize,
    column: usize,
    old: []const u8,
    new: []const u8,

    pub fn format(f: *const Fix, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("{s}:{d}:{d}", .{ f.file, f.line, f.column });
    }

    /// A temporary file beside the original, renamed over it: a crash or a
    /// full disk must never leave a source file of the user cut in half.
    pub fn write(f: *const Fix, gpa: Allocator, io: Io, d: *Diag) error{ Io, OutOfMemory }!void {
        const cwd = Io.Dir.cwd();
        const text = cwd.readFileAlloc(io, f.file, gpa, .unlimited) catch |e| return f.fail(d, e);
        defer gpa.free(text);
        if (f.at + f.old.len > text.len or !std.mem.eql(u8, text[f.at..][0..f.old.len], f.old))
            return d.fail(error.Io, "{s} changed since it was read", .{f.file});
        const st = cwd.statFile(io, f.file, .{}) catch |e| return f.fail(d, e);
        const dir = std.fs.path.dirname(f.file) orelse ".";
        const tmp = try std.fmt.allocPrint(gpa, "{s}/.{s}.{d}", .{ dir, std.fs.path.basename(f.file), sys.pid() });
        defer gpa.free(tmp);
        writeTmp(io, tmp, &.{ text[0..f.at], f.new, text[f.at + f.old.len ..] }, st.permissions) catch |e| {
            cwd.deleteFile(io, tmp) catch {};
            return f.fail(d, e);
        };
        Io.Dir.rename(cwd, tmp, cwd, f.file, io) catch |e| {
            cwd.deleteFile(io, tmp) catch {};
            return f.fail(d, e);
        };
    }

    fn fail(f: *const Fix, d: *Diag, e: anyerror) error{ Io, OutOfMemory } {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return d.fail(error.Io, "{s}: {s}", .{ f.file, errors.ioText(e) });
    }
};

fn writeTmp(io: Io, tmp: []const u8, parts: []const []const u8, perm: Io.File.Permissions) !void {
    const file = try Io.Dir.cwd().createFile(io, tmp, .{ .truncate = true });
    defer file.close(io);
    for (parts) |p| try file.writeStreamingAll(io, p);
    try file.setPermissions(io, perm);
    try file.sync(io);
}

pub const Answer = enum { yes, no, all };

/// A person can answer: stdin and stderr are terminals, and stderr is not
/// a program's `internal-json` stream.
pub fn interactive(log: *const Log) bool {
    return sys.tty.isTerminal(0) and sys.tty.isTerminal(2) and !log.isJson();
}

/// Asks on stderr whether to make `fix`. End of input is no.
pub fn prompt(log: *Log, io: Io, fix: *const Fix) Answer {
    var qbuf: [1024]u8 = undefined;
    const q = std.fmt.bufPrint(&qbuf, "fix the hash at {f}: '{s}' to '{s}'? [y/n/a] ", .{ fix, fix.old, fix.new }) catch
        "fix the hash? [y/n/a] ";
    log.err(q);
    var buf: [256]u8 = undefined;
    var r = Io.File.stdin().readerStreaming(io, &buf);
    const line = r.interface.takeDelimiter('\n') catch null orelse "";
    const a = std.mem.trim(u8, line, " \t\r\n");
    if (std.mem.eql(u8, a, "y") or std.mem.eql(u8, a, "yes")) return .yes;
    if (std.mem.eql(u8, a, "a") or std.mem.eql(u8, a, "all")) return .all;
    return .no;
}

/// The files `ev` parsed, each copied store path mapped back to its local
/// file; the rest of the store is left out, so nixpkgs is never edited.
/// Sorted and unique, in `arena`.
pub fn localFiles(arena: Allocator, ev: *Evaluator, source_map: []const Pair) ![]const []const u8 {
    var map: provenance.SourceMap = try .fromEval(arena, ev, source_map);
    defer map.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    {
        const files = ev.files;
        files.lock.lockUncancelable(files.io);
        defer files.lock.unlock(files.io);
        for (files.files.items) |f| {
            const p = try map.locate(arena, f.path) orelse f.path;
            if (std.mem.startsWith(u8, p, "/") and path_mod.stripStoreDir(p) == null)
                try out.append(arena, try arena.dupe(u8, p));
        }
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    var n: usize = 0;
    for (out.items) |p| {
        if (n > 0 and std.mem.eql(u8, out.items[n - 1], p)) continue;
        out.items[n] = p;
        n += 1;
    }
    return out.items[0..n];
}

const formats = [_]hash_mod.Format{ .sri, .nix32, .base16, .base64 };

/// Every way a user may have written `h` in a Nix file, each with `got` in
/// the same spelling.
fn spellings(arena: Allocator, h: *const Hash, got: *const Hash) Allocator.Error![formats.len][2][]const u8 {
    var out: [formats.len][2][]const u8 = undefined;
    for (formats, &out) |f, *o| {
        const sri = f == .sri;
        o.* = .{ try h.alloc(arena, f, sri), try got.alloc(arena, f, sri) };
    }
    return out;
}

fn hashChar(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or switch (b) {
        '+', '/', '=', '-' => true,
        else => false,
    };
}

/// Where `needle` stands alone in `text`, not inside a longer hash.
fn findAll(arena: Allocator, text: []const u8, needle: []const u8) Allocator.Error![]usize {
    var out: std.ArrayList(usize) = .empty;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, needle)) |i| {
        const end = i + needle.len;
        const alone = (i == 0 or !hashChar(text[i - 1])) and (end >= text.len or !hashChar(text[end]));
        if (alone) try out.append(arena, i);
        from = i + 1;
    }
    return out.items;
}

/// The fix that writes `got` over `specified`, when exactly one place in
/// `files` holds `specified`; else why not, on `d`. Strings go into `arena`.
pub fn locate(arena: Allocator, io: Io, files: []const []const u8, specified: []const u8, got: []const u8, d: *Diag) error{ Store, Io, OutOfMemory }!Fix {
    var scratch: Diag = .init(arena);
    const want = Hash.parseAny(specified, null, &scratch) catch
        return d.fail(error.Store, "cannot parse '{s}' or '{s}' as a hash", .{ specified, got });
    const new = Hash.parseAny(got, null, &scratch) catch
        return d.fail(error.Store, "cannot parse '{s}' or '{s}' as a hash", .{ specified, got });
    const forms = try spellings(arena, &want, &new);
    const Hit = struct { file: []const u8, text: []const u8, at: usize, old: []const u8, new: []const u8 };
    var hit: ?Hit = null;
    var n: usize = 0;
    for (files) |f| {
        const text = Io.Dir.cwd().readFileAlloc(io, f, arena, .unlimited) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        for (forms) |form| for (try findAll(arena, text, form[0])) |at| {
            n += 1;
            hit = .{ .file = f, .text = text, .at = at, .old = form[0], .new = form[1] };
        };
    }
    if (n != 1)
        return d.fail(error.Store, "'{s}' is in {d} places in the files evaluation read, not one; set it to '{s}' by hand", .{ specified, n, got });
    const h = hit.?;
    const before = h.text[0..h.at];
    const line_start = if (std.mem.lastIndexOfScalar(u8, before, '\n')) |i| i + 1 else 0;
    return .{
        .file = h.file,
        .at = h.at,
        .line = std.mem.count(u8, before, "\n") + 1,
        .column = h.at - line_start + 1,
        .old = h.old,
        .new = h.new,
    };
}

const testing = std.testing;

const fake = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
const got_sri = "sha256-GzabkpW8L2UH4rzBkFdv61RoJl8DQlICqZvY9Ql1MAU=";

fn nixFile(a: Allocator, tmp: *testing.TmpDir, text: []const u8) ![]const u8 {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "default.nix", .data = text });
    return tmp.dir.realPathFileAlloc(testing.io, "default.nix", a);
}

test "one match is rewritten in its own spelling" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const f = try nixFile(a, &tmp, "{\n  hash = \"" ++ fake ++ "\";\n}\n");
        const fix = try locate(a, testing.io, &.{f}, fake, got_sri, &d);
        try fix.write(testing.allocator, testing.io, &d);
        try testing.expectEqual(2, fix.line);
        try testing.expectEqual(11, fix.column);
        try testing.expectEqualStrings(got_sri, fix.new);
        const after = try Io.Dir.cwd().readFileAlloc(testing.io, f, a, .unlimited);
        try testing.expectEqualStrings("{\n  hash = \"" ++ got_sri ++ "\";\n}\n", after);
    }
    {
        const want = try Hash.parseAny(fake, null, &d);
        const nix32 = try want.alloc(a, .nix32, false);
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const f = try nixFile(a, &tmp, try std.fmt.allocPrint(a, "sha256 = \"{s}\";", .{nix32}));
        const fix = try locate(a, testing.io, &.{f}, fake, got_sri, &d);
        try fix.write(testing.allocator, testing.io, &d);
        const got32 = try (try Hash.parseAny(got_sri, null, &d)).alloc(a, .nix32, false);
        try testing.expectEqualStrings(got32, fix.new);
    }
}

test "two matches are left alone" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try nixFile(a, &tmp, "a = \"" ++ fake ++ "\"; b = \"" ++ fake ++ "\";");
    try testing.expectError(error.Store, locate(a, testing.io, &.{f}, fake, got_sri, &d));
    try testing.expect(std.mem.indexOf(u8, d.message(), "in 2 places") != null);
}

test "a longer hash is not a match" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualSlices(usize, &.{}, try findAll(arena.allocator(), "x AAAA x", "AAA"));
    try testing.expectEqualSlices(usize, &.{1}, try findAll(arena.allocator(), "\"AAA\"", "AAA"));
}

test "a file changed since it was read is not written" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try nixFile(a, &tmp, "h = \"" ++ fake ++ "\";");
    const fix = try locate(a, testing.io, &.{f}, fake, got_sri, &d);
    _ = try nixFile(a, &tmp, "h = \"\";");
    try testing.expectError(error.Io, fix.write(testing.allocator, testing.io, &d));
    try testing.expect(std.mem.endsWith(u8, d.message(), " changed since it was read"));
}
