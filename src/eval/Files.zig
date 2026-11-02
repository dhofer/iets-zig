//! Every loaded source, so a `Pos` (an offset into their concatenation) maps
//! back to a file, a line and a column.

const std = @import("std");
const Files = @This();
const Pos = @import("../syntax/pos.zig").Pos;
const bytes = @import("../bytes.zig");
const Allows = @import("../lint/allow.zig").Allows;
const Ast = @import("../syntax/ast.zig").Ast;

pub const File = struct {
    path: []const u8,
    /// Index in the table.
    id: u32 = 0,
    /// The global offset of the first byte.
    base: u32,
    len: u32,
    line_starts: []const u32,
    /// The `# iets: allow` lines, set once the file is compiled or its IR
    /// cache entry loaded, before any of its IR runs.
    allows: Allows = .{},
    /// The source and its second parse, made for the first lint finding
    /// whose site needs them and kept for the next (`lint/report.zig`).
    parsed: ?Parsed = null,
    /// No source to parse, or one that does not: asked once.
    parse_failed: bool = false,
    parse_lock: std.Io.Mutex = .init,

    pub const Parsed = struct { src: []const u8, tree: Ast };

    /// 1-based line and column of a local offset.
    pub fn lineCol(f: *const File, offset: u32) struct { u32, u32 } {
        const i = std.sort.upperBound(u32, f.line_starts, offset, orderU32) - 1;
        return .{ @intCast(i + 1), offset - f.line_starts[i] + 1 };
    }
};

fn orderU32(a: u32, b: u32) std.math.Order {
    return std.math.order(a, b);
}

gpa: std.mem.Allocator,
io: std.Io,
files: std.ArrayList(*File) = .empty,
next_base: u32 = 0,
/// Every worker adds files and looks positions up.
lock: std.Io.Mutex = .init,

pub fn init(gpa: std.mem.Allocator, io: std.Io) Files {
    return .{ .gpa = gpa, .io = io };
}

pub fn deinit(fs: *Files) void {
    for (fs.files.items) |f| {
        fs.gpa.free(f.path);
        fs.gpa.free(f.line_starts);
        f.allows.deinit(fs.gpa);
        if (f.parsed) |*x| {
            fs.gpa.free(x.src);
            x.tree.deinit(fs.gpa);
        }
        fs.gpa.destroy(f);
    }
    fs.files.deinit(fs.gpa);
}

/// Register a source; its positions start at the returned file's `base`.
pub fn add(fs: *Files, path: []const u8, src: []const u8) !*File {
    var starts: std.ArrayList(u32) = .empty;
    errdefer starts.deinit(fs.gpa);
    try starts.append(fs.gpa, 0);
    // A lone `\r` and `\r\n` end lines as `\n` does, as Nix's lexer counts them.
    try starts.ensureTotalCapacity(fs.gpa, src.len / 32 + 2);
    if (!try bytes.newlineStarts(fs.gpa, src, &starts)) {
        starts.shrinkRetainingCapacity(1);
        var i: usize = 0;
        while (std.mem.findAnyPos(u8, src, i, "\r\n")) |nl| {
            i = nl + 1;
            if (src[nl] == '\r' and i < src.len and src[i] == '\n') i += 1;
            try starts.append(fs.gpa, @intCast(i));
        }
    }
    const f = try fs.gpa.create(File);
    errdefer fs.gpa.destroy(f);
    const owned_path = try fs.gpa.dupe(u8, path);
    errdefer fs.gpa.free(owned_path);
    f.* = .{
        .path = owned_path,
        .base = fs.next_base,
        .len = @intCast(src.len),
        .line_starts = try starts.toOwnedSlice(fs.gpa),
    };
    fs.lock.lockUncancelable(fs.io);
    defer fs.lock.unlock(fs.io);
    f.base = fs.next_base;
    f.id = @intCast(fs.files.items.len);
    try fs.files.append(fs.gpa, f);
    // One byte of slack so the end-of-file position stays inside the file.
    fs.next_base += @intCast(src.len + 1);
    return f;
}

pub const Loc = struct { file: *File, line: u32, column: u32 };

/// The file of `pos` and the offset in it, without the line.
pub fn fileOf(fs: *const Files, pos: Pos) ?struct { file: *File, off: u32 } {
    if (pos == .none) return null;
    const p = @backingInt(pos);
    const lock = @constCast(&fs.lock);
    lock.lockUncancelable(fs.io);
    defer lock.unlock(fs.io);
    const items = fs.files.items;
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (items[mid].base <= p) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) return null;
    const f = items[lo - 1];
    if (p > f.base + f.len) return null;
    return .{ .file = f, .off = p - f.base };
}

pub fn locate(fs: *const Files, pos: Pos) ?Loc {
    if (pos == .none) return null;
    const p = @backingInt(pos);
    // The lock is a const cast away: a lookup changes nothing.
    const lock = @constCast(&fs.lock);
    lock.lockUncancelable(fs.io);
    defer lock.unlock(fs.io);
    const items = fs.files.items;
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (items[mid].base <= p) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) return null;
    const f = items[lo - 1];
    if (p > f.base + f.len) return null;
    const line, const col = f.lineCol(p - f.base);
    return .{ .file = f, .line = line, .column = col };
}

/// `file:line:col`, or `«none»`.
pub fn at(fs: *const Files, pos: Pos) At {
    return .{ .loc = fs.locate(pos) };
}

pub const At = struct {
    loc: ?Loc,

    pub fn format(a: At, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const l = a.loc orelse return w.writeAll("«none»");
        try w.print("{s}:{d}:{d}", .{ l.file.path, l.line, l.column });
    }
};

test "positions map back to lines" {
    var fs: Files = .init(std.testing.allocator, std.testing.io);
    defer fs.deinit();
    const a = try fs.add("/a.nix", "x\ny\r\nz");
    const b = try fs.add("/b.nix", "q");
    const l = fs.locate(@fromBackingInt(@intCast(a.base + 5))).?;
    try std.testing.expectEqual(3, l.line);
    try std.testing.expectEqual(1, l.column);
    try std.testing.expectEqualStrings("/b.nix", fs.locate(@fromBackingInt(@intCast(b.base))).?.file.path);
}
