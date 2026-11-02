//! A tar reader with the rules of the `tar` crate (0.4.46) that Rust iets
//! reads archives with, so a member is named, sized and placed exactly as
//! there: ustar and GNU headers, GNU long names and long links, pax local
//! headers (`path`, `linkpath` and `size`), and old-style GNU sparse members.
//! std.tar applies other rules (it skips unknown types and refuses some the
//! crate takes), so it does not fit.
//!
//! The archive is read by offset and never held: a member's data is where
//! `file_pos` says, and only headers, long names and pax records are read.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Diag = @import("../diag.zig").Diag;

pub const block = 512;

/// Where the archive's bytes are: a spooled file, read by offset, or memory.
pub const Source = union(enum) {
    file: struct { io: Io, file: Io.File },
    bytes: []const u8,

    /// Up to `buf.len` bytes at `off`; fewer only at the end.
    pub fn readAt(s: Source, buf: []u8, off: u64) error{ReadFailed}!usize {
        switch (s) {
            .bytes => |b| {
                if (off >= b.len) return 0;
                const n = @min(buf.len, b.len - off);
                @memcpy(buf[0..n], b[@intCast(off)..][0..n]);
                return n;
            },
            .file => |f| return f.file.readPositionalAll(f.io, buf, off) catch error.ReadFailed,
        }
    }
};

pub const Error = error{ BadArchive, ReadFailed } || Allocator.Error;

/// The type flags the crate names; any other byte is a regular file to
/// libarchive and to the index.
pub const Type = struct {
    pub const regular = '0';
    pub const link = '1';
    pub const symlink = '2';
    pub const char = '3';
    pub const block_dev = '4';
    pub const directory = '5';
    pub const fifo = '6';
    pub const pax_local = 'x';
    pub const pax_global = 'g';
    pub const gnu_long_name = 'L';
    pub const gnu_long_link = 'K';
    pub const gnu_sparse = 'S';

    /// The type's name in error messages, as Rust iets prints it.
    pub fn debugName(t: u8) []const u8 {
        return switch (t) {
            0, '0' => "Regular",
            '1' => "Link",
            '2' => "Symlink",
            '3' => "Char",
            '4' => "Block",
            '5' => "Directory",
            '6' => "Fifo",
            '7' => "Continuous",
            'x' => "XHeader",
            'g' => "XGlobalHeader",
            'L' => "GNULongName",
            'K' => "GNULongLink",
            'S' => "GNUSparse",
            else => "__Nonexhaustive",
        };
    }
};

/// One run of an old-style GNU sparse member: zeros, or bytes of the archive.
pub const Run = struct { data: bool, archive_at: u64, len: u64 };

pub const Entry = struct {
    header: [block]u8,
    typeflag: u8,
    /// The member's size: the header's or the pax `size`, and for an old-style
    /// sparse member the size it expands to.
    size: u64,
    /// Where the member's data starts in the archive.
    file_pos: u64,
    long_name: ?[]const u8 = null,
    long_link: ?[]const u8 = null,
    pax: ?[]const u8 = null,
    /// The runs of an old-style GNU sparse member.
    sparse: ?[]const Run = null,

    pub fn isUstar(e: *const Entry) bool {
        return std.mem.eql(u8, e.header[257..263], "ustar\x00") and std.mem.eql(u8, e.header[263..265], "00");
    }

    pub fn isGnu(e: *const Entry) bool {
        return std.mem.eql(u8, e.header[257..263], "ustar ") and std.mem.eql(u8, e.header[263..265], " \x00");
    }

    /// The member's name: a GNU long name, else the pax `path`, else the
    /// header's (with the ustar prefix), copied into `a` when it is the
    /// header's, since the entry is a value.
    pub fn path(e: *const Entry, a: Allocator) Allocator.Error![]const u8 {
        if (e.long_name) |n| return if (n.len > 0 and n[n.len - 1] == 0) n[0 .. n.len - 1] else n;
        if (e.pax) |p| if (paxValue(p, "path")) |v| return v;
        return headerPath(&e.header, a);
    }

    pub fn linkName(e: *const Entry) ?[]const u8 {
        if (e.long_link) |n| return if (n.len > 0 and n[n.len - 1] == 0) n[0 .. n.len - 1] else n;
        if (e.pax) |p| if (paxValue(p, "linkpath")) |v| return v;
        if (e.header[157] == 0) return null;
        return truncate(e.header[157..257]);
    }

    pub fn mode(e: *const Entry) ?u32 {
        const m = octal(e.header[100..108]) orelse return null;
        return @truncate(m);
    }
};

fn headerPath(h: *const [block]u8, a: Allocator) Allocator.Error![]const u8 {
    const name = h[0..100];
    const ustar = std.mem.eql(u8, h[257..263], "ustar\x00") and std.mem.eql(u8, h[263..265], "00");
    if (!ustar) return a.dupe(u8, truncate(name));
    const prefix = h[345..500];
    if (prefix[0] == 0 and std.mem.indexOfScalar(u8, name, '\\') == null) return a.dupe(u8, truncate(name));
    const p = truncate(prefix);
    if (p.len == 0) return a.dupe(u8, truncate(name));
    return std.mem.concat(a, u8, &.{ p, "/", truncate(name) });
}

pub fn truncate(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfScalar(u8, s, 0) orelse s.len];
}

/// An octal field, whitespace trimmed, as `u64::from_str_radix(_, 8)` takes it.
fn octal(field: []const u8) ?u64 {
    var t = std.mem.trim(u8, truncate(field), " \t\n\r\x0b\x0c");
    if (t.len > 0 and t[0] == '+') t = t[1..];
    if (t.len == 0) return null;
    return std.fmt.parseInt(u64, t, 8) catch null;
}

/// A numeric field: octal, or base-256 when its first byte has the top bit.
fn number(field: []const u8) ?u64 {
    if (field[0] & 0x80 == 0) return octal(field);
    var v: u64 = 0;
    var skip: usize = 1;
    if (field.len == 8) v = field[0] ^ 0x80 else skip = field.len - 8;
    for (field[skip..]) |b| v = (v << 8) | b;
    return v;
}

/// One pax record: `<len> <key>=<value>`.
pub const PaxRecord = struct { key: []const u8, value: []const u8 };

/// The records of a pax header, split as the crate splits them: at each
/// newline, so a value holding one is malformed.
pub const PaxIterator = struct {
    rest: []const u8,
    done: bool = false,

    /// Null at the end; `error.BadArchive` for a malformed record.
    pub fn next(it: *PaxIterator) error{BadArchive}!?PaxRecord {
        if (it.done) return null;
        const nl = std.mem.indexOfScalar(u8, it.rest, '\n');
        const line = it.rest[0 .. nl orelse it.rest.len];
        if (nl) |i| it.rest = it.rest[i + 1 ..] else it.done = true;
        if (line.len == 0) {
            it.done = true;
            return null;
        }
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return error.BadArchive;
        const len = std.fmt.parseInt(usize, line[0..sp], 10) catch return error.BadArchive;
        if (line.len + 1 != len) return error.BadArchive;
        const kv = line[sp + 1 ..];
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse return error.BadArchive;
        return .{ .key = kv[0..eq], .value = kv[eq + 1 ..] };
    }
};

pub fn paxRecords(p: []const u8) PaxIterator {
    return .{ .rest = p };
}

/// The value of the first well-formed record named `key`, as the crate's
/// `path_bytes` finds it: malformed records are passed over.
fn paxValue(p: []const u8, key: []const u8) ?[]const u8 {
    var it = paxRecords(p);
    while (true) {
        const r = it.next() catch continue orelse return null;
        if (std.mem.eql(u8, r.key, key)) return r.value;
    }
}

/// `pax_extensions_value`: the first record named `key` as a number; a
/// malformed record before it ends the search.
fn paxNumber(p: []const u8, key: []const u8) ?u64 {
    var it = paxRecords(p);
    while (true) {
        const r = (it.next() catch return null) orelse return null;
        if (!std.mem.eql(u8, r.key, key)) continue;
        return std.fmt.parseInt(u64, r.value, 10) catch null;
    }
}

/// The archive's members, one after the other. Long names, pax records and
/// sparse maps live in `arena` until the caller resets it.
pub const Archive = struct {
    src: Source,
    next_at: u64 = 0,

    /// `next_entry`: the next member with the extension headers before it
    /// applied, or null at the end of the archive.
    pub fn next(a: *Archive, arena: Allocator, d: *Diag) Error!?Entry {
        var long_name: ?[]const u8 = null;
        var long_link: ?[]const u8 = null;
        var pax: ?[]const u8 = null;
        var processed: usize = 0;
        while (true) {
            processed += 1;
            var e = (try a.raw(pax, d)) orelse {
                if (processed > 1) return d.fail(error.BadArchive, "members found describing a future member but no future member found", .{});
                return null;
            };
            const known = e.isGnu() or e.isUstar();
            if (known and e.typeflag == Type.gnu_long_name) {
                if (long_name != null) return d.fail(error.BadArchive, "two long name entries describing the same member", .{});
                long_name = try a.readAll(arena, &e);
                continue;
            }
            if (known and e.typeflag == Type.gnu_long_link) {
                if (long_link != null) return d.fail(error.BadArchive, "two long name entries describing the same member", .{});
                long_link = try a.readAll(arena, &e);
                continue;
            }
            if (known and e.typeflag == Type.pax_local) {
                if (pax != null) return d.fail(error.BadArchive, "two pax extensions entries describing the same member", .{});
                pax = try a.readAll(arena, &e);
                continue;
            }
            e.long_name = long_name;
            e.long_link = long_link;
            e.pax = pax;
            if (e.typeflag == Type.gnu_sparse) try a.sparse(arena, &e, d);
            return e;
        }
    }

    /// The member's data whole, to the end of the archive at most.
    pub fn readAll(a: *Archive, arena: Allocator, e: *const Entry) Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        var buf: [16 * 1024]u8 = undefined;
        var at = e.file_pos;
        var left = e.size;
        while (left > 0) {
            const want: usize = @intCast(@min(left, buf.len));
            const n = try a.src.readAt(buf[0..want], at);
            if (n == 0) break;
            try out.appendSlice(arena, buf[0..n]);
            at += n;
            left -= n;
        }
        return out.items;
    }

    /// The next header of any type, as the crate's `next_entry_raw` reads it.
    fn raw(a: *Archive, pax: ?[]const u8, d: *Diag) Error!?Entry {
        var h: [block]u8 = undefined;
        while (true) {
            if (!try a.readBlock(&h, d)) return null;
            if (!std.mem.allEqual(u8, &h, 0)) {
                a.next_at += block;
                break;
            }
            // two zero blocks, or one, end the archive: the crate does not
            // ignore zeros
            return null;
        }
        var sum: u64 = 8 * 32;
        for (h[0..148]) |b| sum += b;
        for (h[156..]) |b| sum += b;
        const want = octal(h[148..156]) orelse {
            const p = truncate(h[0..100]);
            return d.fail(error.BadArchive, "numeric field was not a number: {s} when getting cksum for {s}", .{ truncate(h[148..156]), p });
        };
        if (sum != want) return d.fail(error.BadArchive, "archive header checksum mismatch", .{});

        const t = h[156];
        const extension = t == Type.gnu_long_name or t == Type.gnu_long_link or t == Type.pax_local or t == Type.pax_global;
        var size = number(h[124..136]) orelse
            return d.fail(error.BadArchive, "numeric field was not a number: {s} when getting size for {s}", .{ truncate(h[124..136]), truncate(h[0..100]) });
        if (!extension) if (pax) |p| if (paxNumber(p, "size")) |s| {
            size = s;
        };
        const e: Entry = .{ .header = h, .typeflag = t, .size = size, .file_pos = a.next_at };
        const padded = std.math.add(u64, size, block - 1) catch return d.fail(error.BadArchive, "size overflow", .{});
        a.next_at = std.math.add(u64, a.next_at, padded & ~@as(u64, block - 1)) catch return d.fail(error.BadArchive, "size overflow", .{});
        return e;
    }

    /// One whole block at `next_at`: false at the end of the archive.
    fn readBlock(a: *Archive, h: *[block]u8, d: *Diag) Error!bool {
        const n = try a.src.readAt(h, a.next_at);
        if (n == 0) return false;
        if (n < block) return d.fail(error.BadArchive, "failed to read entire block", .{});
        return true;
    }

    /// As the crate's `parse_sparse_header`: the runs of an old-style GNU
    /// sparse member, from its header and the extension headers after it.
    fn sparse(a: *Archive, arena: Allocator, e: *Entry, d: *Diag) Error!void {
        if (!e.isGnu()) return d.fail(error.BadArchive, "sparse entry type listed but not GNU header", .{});
        var runs: std.ArrayList(Run) = .empty;
        var cur: u64 = 0;
        var remaining = e.size;
        const size = e.size;
        // the extension headers come first, then the data of every run
        var ext_blocks: u64 = 0;
        var data_at: u64 = 0;
        const Add = struct {
            fn run(rs: *std.ArrayList(Run), ar: Allocator, dd: *Diag, entry: []const u8, c: *u64, rem: *u64, sz: u64, at: *u64) Error!void {
                if (entry[0] == 0 or entry[12] == 0) return;
                const off = number(entry[0..12]) orelse return dd.fail(error.BadArchive, "numeric field was not a number when getting offset from sparse header", .{});
                const len = number(entry[12..24]) orelse return dd.fail(error.BadArchive, "numeric field was not a number when getting length from sparse header", .{});
                if (len != 0 and (sz - rem.*) % block != 0)
                    return dd.fail(error.BadArchive, "previous block in sparse file was not aligned to 512-byte boundary", .{});
                if (off < c.*) return dd.fail(error.BadArchive, "out of order or overlapping sparse blocks", .{});
                if (c.* < off) try rs.append(ar, .{ .data = false, .archive_at = 0, .len = off - c.* });
                c.* = std.math.add(u64, off, len) catch return dd.fail(error.BadArchive, "more bytes listed in sparse file than u64 can hold", .{});
                rem.* = std.math.sub(u64, rem.*, len) catch return dd.fail(error.BadArchive, "sparse file consumed more data than the header listed", .{});
                try rs.append(ar, .{ .data = true, .archive_at = at.*, .len = len });
                at.* += len;
            }
        };
        // the runs' archive offsets are known once every extension header is
        // read, so they are collected relative to the data and placed after
        var rel_runs: std.ArrayList(Run) = .empty;
        for (0..4) |i| try Add.run(&rel_runs, arena, d, e.header[386 + i * 24 ..][0..24], &cur, &remaining, size, &data_at);
        var extended = e.header[482] == 1;
        while (extended) {
            var x: [block]u8 = undefined;
            const n = try a.src.readAt(&x, e.file_pos + ext_blocks * block);
            if (n < block) return d.fail(error.BadArchive, "failed to read extension", .{});
            ext_blocks += 1;
            a.next_at += block;
            for (0..21) |i| try Add.run(&rel_runs, arena, d, x[i * 24 ..][0..24], &cur, &remaining, size, &data_at);
            extended = x[504] == 1;
        }
        const real = number(e.header[483..495]) orelse return d.fail(error.BadArchive, "numeric field was not a number when getting real_size", .{});
        if (cur != real) return d.fail(error.BadArchive, "mismatch in sparse file chunks and size in header", .{});
        if (remaining > 0) return d.fail(error.BadArchive, "mismatch in sparse file chunks and entry size in header", .{});
        const base = e.file_pos + ext_blocks * block;
        for (rel_runs.items) |r| try runs.append(arena, .{ .data = r.data, .archive_at = if (r.data) base + r.archive_at else 0, .len = r.len });
        e.sparse = runs.items;
        e.size = cur;
    }
};

const testing = std.testing;

/// A ustar header for the tests, as the crate's `Header::new_ustar` with
/// `set_*` and `set_cksum` makes it; `name` goes into the raw field.
pub fn testHeader(out: *[block]u8, name: []const u8, t: u8, mode: u32, size: u64, link: []const u8) void {
    out.* = @splat(0);
    @memcpy(out[0..name.len], name);
    _ = std.fmt.bufPrint(out[100..107], "{o:0>7}", .{mode}) catch unreachable;
    _ = std.fmt.bufPrint(out[108..115], "{o:0>7}", .{0}) catch unreachable;
    _ = std.fmt.bufPrint(out[116..123], "{o:0>7}", .{0}) catch unreachable;
    _ = std.fmt.bufPrint(out[124..135], "{o:0>11}", .{size}) catch unreachable;
    _ = std.fmt.bufPrint(out[136..147], "{o:0>11}", .{0}) catch unreachable;
    out[156] = t;
    @memcpy(out[157..][0..link.len], link);
    @memcpy(out[257..263], "ustar\x00");
    @memcpy(out[263..265], "00");
    @memset(out[148..156], ' ');
    var sum: u32 = 0;
    for (out) |b| sum += b;
    _ = std.fmt.bufPrint(out[148..155], "{o:0>6}\x00", .{sum}) catch unreachable;
}

/// A tar of `members` (name, type flag, mode, data or link target), with the
/// two zero blocks at the end; a link's bytes are its target.
pub fn testTar(a: Allocator, members: []const TestMember) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (members) |m| {
        const carries = m.t != Type.directory and m.t != Type.symlink and m.t != Type.link;
        var h: [block]u8 = undefined;
        testHeader(&h, m.name, m.t, m.mode, if (carries) m.data.len else 0, if (carries) "" else m.data);
        try out.appendSlice(a, &h);
        if (carries) {
            try out.appendSlice(a, m.data);
            try out.appendNTimes(a, 0, (block - m.data.len % block) % block);
        }
    }
    try out.appendNTimes(a, 0, 2 * block);
    return out.toOwnedSlice(a);
}

pub const TestMember = struct { name: []const u8, t: u8, mode: u32 = 0o644, data: []const u8 = "" };

test "members, long names and pax paths are read as the crate reads them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const long = "d/" ++ @as([150]u8, @splat('x'));
    var pax_body: std.ArrayList(u8) = .empty;
    const rec = " path=" ++ long ++ "\n";
    try pax_body.print(a, "{d}{s}", .{ rec.len + 3, rec });
    const bytes = try testTar(a, &.{
        .{ .name = "top/", .t = Type.directory, .mode = 0o755 },
        .{ .name = "top/f", .t = Type.regular, .data = "hello" },
        .{ .name = "././@LongLink", .t = Type.gnu_long_name, .data = long ++ "\x00" },
        .{ .name = "short", .t = Type.regular, .data = "a" },
        .{ .name = "PaxHeaders/x", .t = Type.pax_local, .data = pax_body.items },
        .{ .name = "ignored", .t = Type.regular, .data = "bb" },
        .{ .name = "l", .t = Type.symlink, .data = "top/f" },
    });
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var ar: Archive = .{ .src = .{ .bytes = bytes } };
    var names: std.ArrayList([]const u8) = .empty;
    while (try ar.next(a, &d)) |e| try names.append(a, try e.path(a));
    try testing.expectEqual(@as(usize, 5), names.items.len);
    try testing.expectEqualStrings("top/f", names.items[1]);
    try testing.expectEqualStrings(long, names.items[2]);
    try testing.expectEqualStrings(long, names.items[3]);
    ar = .{ .src = .{ .bytes = bytes } };
    _ = try ar.next(a, &d);
    const f = (try ar.next(a, &d)).?;
    try testing.expectEqualStrings("hello", bytes[@intCast(f.file_pos)..][0..@intCast(f.size)]);
    try testing.expectEqual(@as(u32, 0o644), f.mode().?);
}

test "a bad checksum and a pax header with no member are errors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const bytes = try testTar(a, &.{.{ .name = "f", .t = Type.regular, .data = "x" }});
    bytes[0] = 'g';
    var ar: Archive = .{ .src = .{ .bytes = bytes } };
    try testing.expectError(error.BadArchive, ar.next(a, &d));
    try testing.expectEqualStrings("archive header checksum mismatch", d.message());
    const lone = try testTar(a, &.{.{ .name = "x", .t = Type.pax_local, .data = "9 a=bcd\n" }});
    ar = .{ .src = .{ .bytes = lone } };
    try testing.expectError(error.BadArchive, ar.next(a, &d));
}
