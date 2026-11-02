//! What a command puts on a terminal: the stdout writer, sizes, and the text
//! layout of the values `api/render.zig` produces.

const std = @import("std");
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;
const Session = @import("../session.zig").Session;
const log = @import("../log.zig");
const errors = @import("../errors.zig");
const Diag = @import("../diag.zig").Diag;
const api_render = @import("../api/render.zig");

/// Everything a command writes on stdout goes through here. A write that
/// fails is an error the command reports: exit 0 is the promise that the
/// output reached stdout, and `logger->writeToStdout` throws for the same
/// reason.
pub fn bytes(s: *Session, b: []const u8) error{WriteFailed}!void {
    return s.out.writeAll(b);
}

/// `b` on stdout. A write that fails is an `io` error in `d` that names the
/// bytes and the OS error.
pub fn write(s: *Session, b: []const u8, d: *Diag) error{Io}!void {
    s.out.writeAll(b) catch return d.fail(error.Io, "write of {d} bytes: {s}", .{ b.len, errors.errnoText(s.out.failure) });
}

/// A value's JSON or its text on stdout, as `--json` asks.
pub fn emit(s: *Session, a: Allocator, v: anytype, as_json: bool) !void {
    var buf: Writer.Allocating = .init(a);
    defer buf.deinit();
    if (as_json) {
        try v.json(&buf.writer);
        try buf.writer.writeByte('\n');
    } else try v.text(&buf.writer);
    try bytes(s, buf.written());
}

/// util.cc:renderSize: KiB at least, one decimal.
pub fn size(w: *Writer, b: u64) Writer.Error!void {
    return (@import("../progress.zig").Size{ .b = b }).format(w);
}

/// A status line on stderr: what a run did, not what it produced.
pub fn status(s: *Session, text: []const u8) void {
    s.log.textLine(text);
}

/// shared.cc:printMissing at lvlError, as `nix build --dry-run` prints it. It
/// is a log record, not output: `--json` prints the contract beside it, as
/// Nix does.
pub fn missing(s: *Session, a: Allocator, m: *const api_render.Missing) !void {
    var sz: Writer.Allocating = .init(a);
    try size(&sz.writer, m.download_size);
    try sz.writer.writeAll(" download, ");
    try size(&sz.writer, m.nar_size);
    try sz.writer.writeAll(" unpacked");
    const sizes = sz.written();
    const unknown = "don't know how to build these paths:";
    const sections = [_]struct { paths: []const []const u8, one: []const u8, many: []const u8 }{
        .{ .paths = m.will_build, .one = "this derivation will be built:", .many = try std.fmt.allocPrint(a, "these {d} derivations will be built:", .{m.will_build.len}) },
        .{ .paths = m.will_substitute, .one = try std.fmt.allocPrint(a, "this path will be fetched ({s}):", .{sizes}), .many = try std.fmt.allocPrint(a, "these {d} paths will be fetched ({s}):", .{ m.will_substitute.len, sizes }) },
        .{ .paths = m.unknown, .one = unknown, .many = unknown },
    };
    for (sections) |sec| {
        if (sec.paths.len == 0) continue;
        s.log.msg(0, if (sec.paths.len == 1) sec.one else sec.many);
        for (sec.paths) |p| s.log.msg(0, try std.fmt.allocPrint(a, "  {s}", .{p}));
    }
}

/// The closing line of a build of several roots.
pub fn built(s: *Session, a: Allocator, o: api_render.Outcomes) !void {
    var line: Writer.Allocating = .init(a);
    var failed: usize = 0;
    for (o.items) |x| if (!x.success) {
        failed += 1;
    };
    try line.writer.print("{d} built, {d} failed", .{ o.items.len - failed, failed });
    var first = true;
    for (o.items) |x| if (!x.success) {
        try line.writer.writeAll(if (first) ": " else ", ");
        try line.writer.writeAll(x.attr);
        first = false;
    };
    status(s, line.written());
}

/// `iets diff --closure`: one line per package whose versions differ.
pub fn closureText(w: *Writer, c: *const api_render.Closure) Writer.Error!void {
    if (c.isEmpty()) return w.writeAll("the two closures hold the same packages\n");
    for (c.packages) |p| {
        if (std.mem.eql(u8, p.change, "added")) {
            try w.print("added   {s} ", .{p.name});
            try join(w, p.b);
        } else if (std.mem.eql(u8, p.change, "removed")) {
            try w.print("removed {s} ", .{p.name});
            try join(w, p.a);
        } else {
            try w.print("changed {s} ", .{p.name});
            try join(w, p.a);
            try w.writeAll(" -> ");
            try join(w, p.b);
        }
        try w.writeByte('\n');
    }
}

fn join(w: *Writer, v: []const []const u8) Writer.Error!void {
    for (v, 0..) |x, k| {
        if (k > 0) try w.writeAll(", ");
        try w.writeAll(x);
    }
}

/// `iets diff`. `gpa` holds the lines of a value while they are compared.
pub fn diffText(gpa: Allocator, w: *Writer, d: *const api_render.Diff) Writer.Error!void {
    if (d.isEmpty()) return w.print("{f} and {f} are the same derivation\n", .{ &d.a, &d.b });
    try diffNodeText(gpa, w, d, 0);
}

/// One node of the walk: its own differences, then each input derivation
/// that differs, indented.
fn diffNodeText(gpa: Allocator, w: *Writer, d: *const api_render.Diff, ind: usize) Writer.Error!void {
    const body = ind + 2;
    try w.splatByteAll(' ', ind);
    try w.print("- {f}\n", .{&d.a});
    try w.splatByteAll(' ', ind);
    try w.print("+ {f}\n", .{&d.b});
    for (d.items) |i| {
        if (i.a == null and i.b == null) continue;
        try w.splatByteAll(' ', body);
        if (i.b == null or i.a == null) {
            const v = i.a orelse i.b.?;
            try w.print("{s} {s}: ", .{ i.what, if (i.b == null) "removed" else "added" });
            if (i.key.len > 0) try w.print("{s}=", .{i.key});
            try oneLine(w, v);
            try w.writeByte('\n');
            continue;
        }
        const x = i.a.?;
        const y = i.b.?;
        if (i.key.len == 0 and short(x, y)) {
            try w.print("{s}: {s} -> {s}\n", .{ i.what, x, y });
            continue;
        }
        if (i.key.len == 0) try w.print("{s}:\n", .{i.what}) else try w.print("{s} {s}:\n", .{ i.what, i.key });
        try lineDiff(gpa, w, x, y, 20, body + 2);
    }
    for (d.changed) |*c| {
        try w.splatByteAll(' ', body);
        try w.print("input drv changed: {s}\n", .{drvName(&c.a)});
        try diffNodeText(gpa, w, c, ind + 4);
    }
    if (d.cut) |c| {
        try w.splatByteAll(' ', body);
        try w.print("(stopped: {s}; use --all)\n", .{c});
    }
}

/// Two values that fit on one line together.
fn short(a: []const u8, b: []const u8) bool {
    return a.len + b.len < 100 and std.mem.indexOfScalar(u8, a, '\n') == null and std.mem.indexOfScalar(u8, b, '\n') == null;
}

/// `NAME` of `<hash>-NAME.drv`.
fn drvName(p: *const api_render.StorePath) []const u8 {
    const name = p.name();
    return if (std.mem.endsWith(u8, name, ".drv")) name[0 .. name.len - 4] else name;
}

/// A value on one line of output: newlines shown as `\n`, values longer
/// than 200 code points cut.
fn oneLine(w: *Writer, v: []const u8) Writer.Error!void {
    var i: usize = 0;
    var n: usize = 0;
    while (i < v.len and n < 200) : (n += 1) {
        const len = std.unicode.utf8ByteSequenceLength(v[i]) catch 1;
        const end = @min(i + len, v.len);
        if (v[i] == '\n') try w.writeAll("\\n") else try w.writeAll(v[i..end]);
        i = end;
    }
    if (i < v.len) try w.writeAll("…");
}

/// `str::lines`: split at `\n`, a `\r` before it dropped, no last empty line.
fn lines(arena: Allocator, s: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |l| {
        if (it.index == null and l.len == 0) break;
        try out.append(arena, if (std.mem.endsWith(u8, l, "\r")) l[0 .. l.len - 1] else l);
    }
    return out.items;
}

/// A compact diff of two values, each line indented by `pad`: the common
/// head and tail lines are left out, and at most `cap` lines of each side
/// are shown.
fn lineDiff(gpa: Allocator, w: *Writer, a: []const u8, b: []const u8, cap: usize, pad: usize) Writer.Error!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const la = lines(arena.allocator(), a) catch return error.WriteFailed;
    const lb = lines(arena.allocator(), b) catch return error.WriteFailed;
    if (la.len < 2 and lb.len < 2) {
        try w.splatByteAll(' ', pad);
        try w.writeAll("- ");
        try oneLine(w, a);
        try w.writeByte('\n');
        try w.splatByteAll(' ', pad);
        try w.writeAll("+ ");
        try oneLine(w, b);
        try w.writeByte('\n');
        return;
    }
    var head: usize = 0;
    while (head < la.len and head < lb.len and std.mem.eql(u8, la[head], lb[head])) head += 1;
    const ra = la[head..];
    const rb = lb[head..];
    var tail: usize = 0;
    while (tail < ra.len and tail < rb.len and std.mem.eql(u8, ra[ra.len - 1 - tail], rb[rb.len - 1 - tail])) tail += 1;
    if (head > 0) {
        try w.splatByteAll(' ', pad);
        try w.print("@@ line {d}\n", .{head + 1});
    }
    for ([_]struct { u8, []const []const u8 }{ .{ '-', ra[0 .. ra.len - tail] }, .{ '+', rb[0 .. rb.len - tail] } }) |side| {
        const mark, const ls = side;
        for (ls[0..@min(cap, ls.len)]) |l| {
            try w.splatByteAll(' ', pad);
            try w.print("{c} ", .{mark});
            try oneLine(w, l);
            try w.writeByte('\n');
        }
        if (ls.len > cap) {
            try w.splatByteAll(' ', pad);
            try w.print("{c} … {d} more lines\n", .{ mark, ls.len - cap });
        }
    }
}

const testing = std.testing;

fn lineDiffOf(a: []const u8, b: []const u8) ![]u8 {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try lineDiff(testing.allocator, &out.writer, a, b, 20, 0);
    return out.toOwnedSlice();
}

test "a long value shows the lines that differ" {
    const got = try lineDiffOf("one\ntwo\nthree\nfour", "one\ntwo two\nthree\nfour");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("@@ line 2\n- two\n+ two two\n", got);
    const one = try lineDiffOf("x", "y");
    defer testing.allocator.free(one);
    try testing.expectEqualStrings("- x\n+ y\n", one);
}

test "a long side is capped" {
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(testing.allocator);
    for (0..25) |i| try a.print(testing.allocator, "l{d}\n", .{i});
    const got = try lineDiffOf(a.items, "x\ny");
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "- … 5 more lines\n") != null);
    try testing.expect(std.mem.endsWith(u8, got, "+ x\n+ y\n"));
}

test "the text of a diff" {
    var d: @import("../diag.zig").Diag = .init(testing.allocator);
    defer d.deinit();
    const SP = api_render.StorePath;
    const a = try SP.fromBaseName("00000000000000000000000000000000-top.drv", &d);
    const b = try SP.fromBaseName("11111111111111111111111111111111-top.drv", &d);
    const ca = try SP.fromBaseName("00000000000000000000000000000000-dep.drv", &d);
    const cb = try SP.fromBaseName("11111111111111111111111111111111-dep.drv", &d);
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try diffText(testing.allocator, &out.writer, &.{ .a = a, .b = a });
    try testing.expectEqualStrings("/nix/store/00000000000000000000000000000000-top.drv and /nix/store/00000000000000000000000000000000-top.drv are the same derivation\n", out.written());

    const items = [_]api_render.DiffItem{
        .{ .what = "platform", .a = "x86_64-linux", .b = "aarch64-linux" },
        .{ .what = "env", .key = "gone", .a = "", .b = null },
        .{ .what = "env", .key = "new", .a = null, .b = "a\nb" },
        .{ .what = "env", .key = "x", .a = "1", .b = "2" },
    };
    const child = [_]api_render.Diff{.{ .a = ca, .b = cb, .cut = "depth" }};
    out.clearRetainingCapacity();
    try diffText(testing.allocator, &out.writer, &.{ .a = a, .b = b, .items = &items, .changed = &child });
    try testing.expectEqualStrings(
        \\- /nix/store/00000000000000000000000000000000-top.drv
        \\+ /nix/store/11111111111111111111111111111111-top.drv
        \\  platform: x86_64-linux -> aarch64-linux
        \\  env removed: gone=
        \\  env added: new=a\nb
        \\  env x:
        \\    - 1
        \\    + 2
        \\  input drv changed: dep
        \\    - /nix/store/00000000000000000000000000000000-dep.drv
        \\    + /nix/store/11111111111111111111111111111111-dep.drv
        \\      (stopped: depth; use --all)
        \\
    , out.written());
}

test "the text of a closure diff" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a_ = arena.allocator();
    var pa = [_]api_render.NameVersion{ .{ .name = "hello", .version = "2.12" }, .{ .name = "bash", .version = "5.2" }, .{ .name = "gone", .version = "1" }, .{ .name = "bash", .version = "5.2" } };
    var pb = [_]api_render.NameVersion{ .{ .name = "hello", .version = "2.13" }, .{ .name = "bash", .version = "5.2" }, .{ .name = "new", .version = "" }, .{ .name = "hello", .version = "2.12" } };
    const c = try api_render.Closure.of(a_, "A", "B", try api_render.Versions.of(a_, &pa), try api_render.Versions.of(a_, &pb));
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try closureText(&out.writer, &c);
    try testing.expectEqualStrings("removed gone 1\nchanged hello 2.12 -> 2.12, 2.13\nadded   new \n", out.written());
}

test "sizes render as nix renders them" {
    const want = [_][]const u8{ "0.1 KiB", "2.0 KiB", "10.3 KiB", "1.5 MiB", "5.6 GiB" };
    for ([_]u64{ 100, 2000, 10547, 1_572_864, 6_000_000_000 }, want) |b, w| {
        var buf: [32]u8 = undefined;
        var fw: Writer = .fixed(&buf);
        try size(&fw, b);
        try std.testing.expectEqualStrings(w, fw.buffered());
    }
}
