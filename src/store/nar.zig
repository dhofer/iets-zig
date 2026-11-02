//! The Nix archive format: writing a NAR from a tree, hashing one, and reading
//! one back. Mirrors libutil's archive.cc.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const Allocator = std.mem.Allocator;
const Diag = @import("../diag.zig").Diag;
const hash_mod = @import("hash.zig");
const Hash = hash_mod.Hash;

/// The Nix type name passed to `builtins.filterSource` filters (primops.cc:fileTypeToString).
pub const FileType = enum {
    regular,
    directory,
    symlink,
    unknown,

    pub fn nixName(t: FileType) []const u8 {
        return @tagName(t);
    }

    pub fn of(kind: File.Kind) FileType {
        return switch (kind) {
            .file => .regular,
            .directory => .directory,
            .sym_link => .symlink,
            else => .unknown,
        };
    }
};

pub const max_depth = 64;

/// The longest entry name the reader accepts: `NAME_MAX`, so a name it accepts
/// is a name the file system can hold.
const max_name = 255;
/// The longest symlink target: `PATH_MAX` less its NUL.
const max_target = 4095;

/// The smallest buffer a `*Io.Reader` handed to the NAR reader may have: a
/// token is matched in place, so the longest one must fit.
pub const min_reader_buffer = max_target + 1;

fn framedLen(comptime toks: []const []const u8) usize {
    var n: usize = 0;
    for (toks) |t| n += 8 + std.mem.alignForward(usize, t.len, 8);
    return n;
}

/// The framed form of a run of constant tokens. Most of a NAR is fixed
/// keywords, so a whole run of them is one copy, and the reader matches it with
/// one compare.
fn framed(comptime toks: []const []const u8) [framedLen(toks)]u8 {
    var out: [framedLen(toks)]u8 = @splat(0);
    var o: usize = 0;
    for (toks) |t| {
        std.mem.writeInt(u64, out[o..][0..8], t.len, .little);
        @memcpy(out[o + 8 ..][0..t.len], t);
        o += 8 + std.mem.alignForward(usize, t.len, 8);
    }
    return out;
}

// The groups nix-community/go-nix PR #123 (pkg/narv2, edef) cuts the format
// into. They are chosen so that the reader can tell the four node shapes apart
// from a single byte: peek 32 bytes at a node's type token and byte 16 is the
// length prefix of whatever follows the type — `target` (6) after `symlink`,
// `contents` (8) after `regular`, `executable` (10) after an executable
// `regular` — except for `directory`, which is long enough that byte 16 is its
// own last letter, `y`.
const tok_nar = framed(&.{ "nix-archive-1", "(", "type" });
const tok_reg = framed(&.{ "regular", "contents" });
const tok_exe = framed(&.{ "regular", "executable", "", "contents" });
const tok_sym = framed(&.{ "symlink", "target" });
const tok_dir = framed(&.{"directory"});
const tok_ent = framed(&.{ "entry", "(", "name" });
const tok_nod = framed(&.{ "node", "(", "type" });
const tok_par = framed(&.{")"});

const tag_sym = 6;
const tag_reg = 8;
const tag_exe = 10;
const tag_dir = 'y';

comptime {
    std.debug.assert(tok_sym[16] == tag_sym and tok_reg[16] == tag_reg and tok_exe[16] == tag_exe and tok_dir[16] == tag_dir);
}

/// The one NAR writer: every NAR byte is framed here. A tree that is walked —
/// a directory on disk, a string — drives it with the nodes it finds, in NAR
/// order. `regular` and `symlink` close their node, `dir` opens one and
/// `endDir` closes it, and `entry`/`endEntry` wrap the child between them.
/// Buffering is the `Io.Writer`'s.
pub const Writer = struct {
    w: *Io.Writer,

    /// `nix-archive-1`, and the head of the root node.
    pub fn header(n: Writer) Io.Writer.Error!void {
        try n.w.writeAll(&tok_nar);
    }

    /// A regular file: exactly `len` bytes read from `src`.
    pub fn regular(n: Writer, executable: bool, len: u64, src: *Io.Reader) Io.Reader.StreamError!void {
        try n.w.writeAll(if (executable) &tok_exe else &tok_reg);
        try n.w.writeInt(u64, len, .little);
        try src.streamExact64(n.w, len);
        try n.padding(len);
        try n.w.writeAll(&tok_par);
    }

    pub fn regularBytes(n: Writer, executable: bool, contents: []const u8) Io.Writer.Error!void {
        try n.w.writeAll(if (executable) &tok_exe else &tok_reg);
        try n.token(contents);
        try n.w.writeAll(&tok_par);
    }

    pub fn symlink(n: Writer, target: []const u8) Io.Writer.Error!void {
        try n.w.writeAll(&tok_sym);
        try n.token(target);
        try n.w.writeAll(&tok_par);
    }

    pub fn dir(n: Writer) Io.Writer.Error!void {
        try n.w.writeAll(&tok_dir);
    }

    /// The head of one directory entry; the child node follows.
    pub fn entry(n: Writer, name: []const u8) Io.Writer.Error!void {
        try n.w.writeAll(&tok_ent);
        try n.token(name);
        try n.w.writeAll(&tok_nod);
    }

    pub fn endEntry(n: Writer) Io.Writer.Error!void {
        try n.w.writeAll(&tok_par);
    }

    pub fn endDir(n: Writer) Io.Writer.Error!void {
        try n.w.writeAll(&tok_par);
    }

    /// One NAR token: length-prefixed, zero-padded to 8.
    fn token(n: Writer, s: []const u8) Io.Writer.Error!void {
        try n.w.writeInt(u64, s.len, .little);
        try n.w.writeAll(s);
        try n.padding(s.len);
    }

    fn padding(n: Writer, len: u64) Io.Writer.Error!void {
        const rem: usize = @intCast(len % 8);
        if (rem != 0) try n.w.splatByteAll(0, 8 - rem);
    }
};

/// Mirrors archive.cc:dumpString: the NAR of a regular, non-executable file with `contents`.
pub fn dumpString(contents: []const u8, w: *Io.Writer) Io.Writer.Error!void {
    const n: Writer = .{ .w = w };
    try n.header();
    try n.regularBytes(false, contents);
}

/// `nix hash path` of a file holding `contents`.
pub fn narHashOfString(contents: []const u8) Hash {
    var h: hash_mod.Hasher = .init(.sha256);
    var buf: [256]u8 = undefined;
    var hw = h.writer(&buf);
    dumpString(contents, &hw.interface) catch unreachable;
    hw.interface.flush() catch unreachable;
    return h.finish();
}

/// A filter that keeps everything, for `dumpPath` without one.
pub const keep_all = struct {
    pub fn accept(_: @This(), _: []const u8, _: FileType) error{}!bool {
        return true;
    }
}{};

/// What `dumpPath` can fail with besides its filter's errors. The file system
/// errors carry a message in the `Diag` that names the path.
pub const DumpError = Allocator.Error || Io.Writer.Error || File.OpenError || File.StatError ||
    Dir.ReadLinkError || Dir.Reader.Error || File.Reader.Error || error{ BadPath, ReadFailed };

fn FilterError(comptime F: type) type {
    const ret = @typeInfo(@TypeOf(F.accept)).@"fn".return_type.?;
    return @typeInfo(ret).error_union.error_set;
}

/// Mirrors archive.cc:SourceAccessor::dumpPath: writes the NAR of `sub_path`
/// (relative to `dir`, or absolute) into `w`, and flushes it.
///
/// `filter` is a value with `fn accept(self, path: []const u8, FileType) !bool`,
/// called on each directory entry with `sub_path/...`; `false` leaves the entry
/// out (archive.hh:PathFilter as primops.cc:addPath uses it). Its errors pass
/// through, so a `filterSource` callback can fail the evaluation.
pub fn dumpPath(
    gpa: Allocator,
    io: Io,
    dir: Dir,
    sub_path: []const u8,
    w: *Io.Writer,
    filter: anytype,
    d: *Diag,
) (DumpError || FilterError(@TypeOf(filter)))!void {
    const st = dir.statFile(io, sub_path, .{ .follow_symlinks = false }) catch |e|
        return d.fail(e, "getting status of '{s}': {t}", .{ sub_path, e });
    var walk: Walk(@TypeOf(filter)) = .{ .gpa = gpa, .io = io, .filter = filter, .d = d, .nar = .{ .w = w } };
    defer walk.deinit();
    // The walk appends "/name", so a trailing slash on the root would double it
    // and change the paths the filter sees.
    var root = sub_path;
    while (root.len > 1 and root[root.len - 1] == '/') root.len -= 1;
    try walk.path.appendSlice(gpa, root);
    try walk.nar.header();
    try walk.node(dir, sub_path, FileType.of(st.kind), 0);
    try w.flush();
}

/// The scratch a dump reuses at every level: one path buffer, one arena of
/// entry names and one entry index, all kept to stack discipline, so walking
/// 40k entries allocates nothing past the first few levels.
fn Walk(comptime Filter: type) type {
    return struct {
        const Self = @This();
        const Error = DumpError || FilterError(Filter);

        gpa: Allocator,
        io: Io,
        filter: Filter,
        d: *Diag,
        nar: Writer,
        /// The path of the node being written, for the filter and for messages.
        path: std.ArrayList(u8) = .empty,
        names: std.ArrayList(u8) = .empty,
        index: std.ArrayList(Entry) = .empty,
        read_buf: [1 << 16]u8 = undefined,

        const Entry = struct { off: u32, len: u32, ft: FileType };

        fn deinit(s: *Self) void {
            s.path.deinit(s.gpa);
            s.names.deinit(s.gpa);
            s.index.deinit(s.gpa);
        }

        fn fail(s: *Self, err: anytype, comptime what: []const u8) @TypeOf(err) {
            return s.d.fail(err, what ++ " '{s}': {t}", .{ s.path.items, err });
        }

        /// Writes the node `name` in `parent`, whose type the parent's listing
        /// — or the root's `lstat` — already told.
        fn node(s: *Self, parent: Dir, name: []const u8, ft: FileType, depth: usize) Error!void {
            if (depth >= max_depth)
                return s.d.fail(error.BadPath, "path '{s}' exceeds maximum NAR directory depth of {d}", .{ s.path.items, max_depth });
            switch (ft) {
                .regular => try s.regular(parent, name),
                .directory => {
                    var sub = parent.openDir(s.io, name, .{ .iterate = true, .follow_symlinks = false }) catch |e|
                        return s.fail(e, "opening directory");
                    defer sub.close(s.io);
                    try s.nar.dir();
                    try s.directory(sub, depth);
                    try s.nar.endDir();
                },
                .symlink => {
                    var buf: [max_target + 1]u8 = undefined;
                    const n = parent.readLink(s.io, name, &buf) catch |e| return s.fail(e, "reading symbolic link");
                    try s.nar.symlink(buf[0..n]);
                },
                .unknown => return s.d.fail(error.BadPath, "file '{s}' has an unsupported type", .{s.path.items}),
            }
        }

        /// `open` then `fstat`, not `lstat` then `open`: the same two syscalls,
        /// but the size and mode announced cannot disagree with the bytes that follow.
        fn regular(s: *Self, parent: Dir, name: []const u8) Error!void {
            const f = parent.openFile(s.io, name, .{ .follow_symlinks = false }) catch |e| return s.fail(e, "opening file");
            defer f.close(s.io);
            const st = f.stat(s.io) catch |e| return s.fail(e, "getting status of");
            if (st.kind != .file) return s.d.fail(error.BadPath, "file '{s}' changed type while being read", .{s.path.items});
            const executable = File.Permissions.has_executable_bit and st.permissions.toMode() & 0o100 != 0;
            var fr = File.Reader.initSize(f, s.io, &s.read_buf, st.size);
            s.nar.regular(executable, st.size, &fr.interface) catch |e| switch (e) {
                error.WriteFailed => return error.WriteFailed,
                error.EndOfStream => return s.d.fail(error.ReadFailed, "file '{s}' ended early while reading contents", .{s.path.items}),
                error.ReadFailed => {
                    const err = fr.err orelse error.ReadFailed;
                    return s.fail(err, "reading file");
                },
            };
        }

        fn directory(s: *Self, sub: Dir, depth: usize) Error!void {
            const name_base = s.names.items.len;
            const idx_base = s.index.items.len;
            var it = sub.iterateAssumeFirstIteration();
            while (it.next(s.io) catch |e| return s.fail(e, "reading directory")) |e| {
                const off = s.names.items.len - name_base;
                try s.names.appendSlice(s.gpa, e.name);
                const ft: FileType = if (e.kind == .unknown) blk: {
                    // a file system whose `dirent` carries no `d_type`
                    const st = sub.statFile(s.io, e.name, .{ .follow_symlinks = false }) catch |err|
                        return s.fail(err, "getting status of");
                    break :blk .of(st.kind);
                } else .of(e.kind);
                try s.index.append(s.gpa, .{ .off = @intCast(off), .len = @intCast(e.name.len), .ft = ft });
            }
            const arena = s.names.items[name_base..];
            std.mem.sortUnstable(Entry, s.index.items[idx_base..], arena, struct {
                fn lt(a: []const u8, x: Entry, y: Entry) bool {
                    return std.mem.lessThan(u8, a[x.off..][0..x.len], a[y.off..][0..y.len]);
                }
            }.lt);
            const path_base = s.path.items.len;
            for (idx_base..s.index.items.len) |i| {
                const e = s.index.items[i];
                try s.path.append(s.gpa, '/');
                try s.path.appendSlice(s.gpa, s.names.items[name_base + e.off ..][0..e.len]);
                if (try s.filter.accept(s.path.items, e.ft)) {
                    // A child directory leaves `names` and `index` exactly as it
                    // found them, so the siblings still to come stay addressable;
                    // it may grow `names`, so the name is sliced again after.
                    try s.nar.entry(s.names.items[name_base + e.off ..][0..e.len]);
                    try s.node(sub, s.names.items[name_base + e.off ..][0..e.len], e.ft, depth + 1);
                    try s.nar.endEntry();
                }
                s.path.shrinkRetainingCapacity(path_base);
            }
            s.index.shrinkRetainingCapacity(idx_base);
            s.names.shrinkRetainingCapacity(name_base);
        }
    };
}

pub const NarHash = struct { hash: Hash, size: u64 };

/// Mirrors store-api.cc:hashPath for NixArchive ingestion, with a filter;
/// returns the hash and the NAR's size.
pub fn narHashFiltered(
    gpa: Allocator,
    io: Io,
    dir: Dir,
    sub_path: []const u8,
    algo: hash_mod.Algo,
    filter: anytype,
    d: *Diag,
) (DumpError || FilterError(@TypeOf(filter)))!NarHash {
    var h: hash_mod.Hasher = .init(algo);
    const buf = try gpa.alloc(u8, 1 << 16);
    defer gpa.free(buf);
    var hw = h.writer(buf);
    try dumpPath(gpa, io, dir, sub_path, &hw.interface, filter, d);
    return .{ .size = h.count, .hash = h.finish() };
}

/// `nix hash path PATH`: sha256 of the NAR of `sub_path`.
pub fn narHash(gpa: Allocator, io: Io, dir: Dir, sub_path: []const u8, d: *Diag) DumpError!Hash {
    return (try narHashFiltered(gpa, io, dir, sub_path, .sha256, keep_all, d)).hash;
}

/// Mirrors store-api.cc:hashPath for Flat ingestion: the hash of the file's bytes.
pub fn flatHash(io: Io, dir: Dir, sub_path: []const u8, algo: hash_mod.Algo, d: *Diag) (File.OpenError || File.Reader.Error || error{ReadFailed})!Hash {
    const f = dir.openFile(io, sub_path, .{}) catch |e| return d.fail(e, "opening file '{s}': {t}", .{ sub_path, e });
    defer f.close(io);
    var h: hash_mod.Hasher = .init(algo);
    var buf: [1 << 16]u8 = undefined;
    var fr = f.readerStreaming(io, &.{});
    while (true) {
        const n = fr.interface.readSliceShort(&buf) catch {
            const e = fr.err orelse error.ReadFailed;
            return d.fail(e, "reading file '{s}': {t}", .{ sub_path, e });
        };
        if (n == 0) return h.finish();
        h.update(buf[0..n]);
    }
}

pub const ReadError = error{ BadNar, ReadFailed };

/// A NAR stream read in place from the reader's buffer.
///
/// The shape is the one nix-community/go-nix PR #123 (pkg/narv2) settled on: a
/// synchronous state machine over a buffered reader with peek and discard, whole
/// token groups matched with one compare against a pre-framed constant, the node
/// shape picked from a single byte of a peeked header, contents streamed by their
/// declared length, and nothing allocated at all: the previous entry name at
/// each depth, which the format requires to be increasing, has a fixed slot.
const Parser = struct {
    r: *Io.Reader,
    d: *Diag,
    /// How much of the stream has been consumed: the NAR's length once done.
    consumed: u64 = 0,
    prev: [max_depth][max_name]u8 = undefined,
    prev_len: [max_depth]u8 = undefined,

    fn init(r: *Io.Reader, d: *Diag) Parser {
        std.debug.assert(r.buffer.len >= min_reader_buffer);
        return .{ .r = r, .d = d };
    }

    fn bad(p: *Parser, comptime why: []const u8, args: anytype) error{BadNar} {
        return p.d.fail(error.BadNar, "bad NAR: " ++ why, args);
    }

    fn short(p: *Parser, e: Io.Reader.Error) ReadError {
        return switch (e) {
            error.EndOfStream => p.bad("stream ended early", .{}),
            error.ReadFailed => error.ReadFailed,
        };
    }

    fn peek(p: *Parser, n: usize) ReadError![]u8 {
        return p.r.peek(n) catch |e| p.short(e);
    }

    fn take(p: *Parser, n: usize) ReadError![]u8 {
        const s = p.r.take(n) catch |e| return p.short(e);
        p.consumed += n;
        return s;
    }

    /// Consumes a run of constant tokens, which the stream must hold exactly.
    fn consume(p: *Parser, comptime run: []const u8, comptime what: []const u8) ReadError!void {
        const got = p.r.peek(run.len) catch |e| switch (e) {
            error.EndOfStream => return p.bad("expected " ++ what, .{}),
            error.ReadFailed => return error.ReadFailed,
        };
        if (!std.mem.eql(u8, got, run)) return p.bad("expected " ++ what, .{});
        p.r.toss(run.len);
        p.consumed += run.len;
    }

    fn int(p: *Parser) ReadError!u64 {
        return std.mem.readInt(u64, (try p.take(8))[0..8], .little);
    }

    fn padding(p: *Parser, len: u64) ReadError!void {
        const rem: usize = @intCast(len % 8);
        if (rem == 0) return;
        for (try p.take(8 - rem)) |b| if (b != 0) return p.bad("non-zero padding", .{});
    }

    /// Mirrors serialise.hh:readString with a size cap. The token is a slice of
    /// the reader's buffer, so it lives only until the next read.
    fn token(p: *Parser, max: usize) ReadError![]const u8 {
        const len = try p.int();
        if (len > max) return p.bad("string too long", .{});
        const n: usize = @intCast(len);
        const s = try p.take(std.mem.alignForward(usize, n, 8));
        for (s[n..]) |b| if (b != 0) return p.bad("non-zero padding", .{});
        return s[0..n];
    }

    /// Which of the four node shapes comes next, from one byte of its header.
    fn nodeTag(p: *Parser) ReadError!u8 {
        const tag = (try p.peek(32))[16];
        return switch (tag) {
            tag_sym, tag_reg, tag_exe, tag_dir => tag,
            else => p.bad("unknown node type", .{}),
        };
    }

    /// Starts a directory's entries at `depth`.
    fn openDir(p: *Parser, depth: usize) void {
        p.prev_len[depth] = 0;
    }

    /// The next entry's name, or null at the `)` that closes the directory
    /// (and the node).
    fn nextEntry(p: *Parser, depth: usize) ReadError!?[]const u8 {
        // 1 is the length prefix of ")", 5 that of "entry".
        switch ((try p.peek(16))[0]) {
            1 => {
                try p.consume(&tok_par, "')'");
                return null;
            },
            5 => {},
            else => return p.bad("expected 'entry' or ')'", .{}),
        }
        try p.consume(&tok_ent, "'entry' '(' 'name'");
        const name = try p.token(max_name);
        // archive.cc:parse's checks of an entry name: well formed, and after
        // the previous name of its directory
        if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or
            std.mem.indexOfAny(u8, name, "/\x00") != null)
            return p.bad("bad entry name", .{});
        const prev = p.prev[depth][0..p.prev_len[depth]];
        if (p.prev_len[depth] > 0 and !std.mem.lessThan(u8, prev, name))
            return p.bad("directory entries out of order", .{});
        @memcpy(p.prev[depth][0..name.len], name);
        p.prev_len[depth] = @intCast(name.len);
        try p.consume(&tok_nod, "'node' '(' 'type'");
        return p.prev[depth][0..name.len];
    }

    /// archive.cc:parse's check of a symlink target.
    fn target(p: *Parser) ReadError![]const u8 {
        try p.consume(&tok_sym, "'symlink' 'target'");
        const t = try p.token(max_target);
        if (t.len == 0 or std.mem.indexOfScalar(u8, t, 0) != null) return p.bad("bad symlink target", .{});
        return t;
    }

    fn regularHead(p: *Parser, tag: u8) ReadError!u64 {
        if (tag == tag_exe)
            try p.consume(&tok_exe, "'regular' 'executable' 'contents'")
        else
            try p.consume(&tok_reg, "'regular' 'contents'");
        return p.int();
    }
};

/// Parses the framing of the NAR in `r`, throwing the file contents away, and
/// returns its length in bytes: whether a NAR is well formed and how long it is,
/// without unpacking it. `r` needs a buffer of `min_reader_buffer` bytes.
pub fn parseLength(r: *Io.Reader, d: *Diag) ReadError!u64 {
    var p: Parser = .init(r, d);
    try p.consume(&tok_nar, "a NAR header");
    try parseNode(&p, 0);
    return p.consumed;
}

fn parseNode(p: *Parser, depth: usize) ReadError!void {
    if (depth >= max_depth) return p.bad("directory nesting too deep", .{});
    switch (try p.nodeTag()) {
        tag_reg, tag_exe => |tag| {
            const len = try p.regularHead(tag);
            p.r.discardAll64(len) catch |e| return p.short(e);
            p.consumed += len;
            try p.padding(len);
        },
        tag_sym => _ = try p.target(),
        else => {
            // the `)` that ends a directory's entries is the node's own
            try p.consume(&tok_dir, "'directory'");
            p.openDir(depth);
            while (try p.nextEntry(depth)) |_| {
                try parseNode(p, depth + 1);
                try p.consume(&tok_par, "')'");
            }
            return;
        },
    }
    try p.consume(&tok_par, "')'");
}

pub const RestoreError = ReadError || Dir.CreateDirError || Dir.OpenError || File.OpenError ||
    Dir.SymLinkError || File.SetPermissionsError || File.Writer.Error || error{WriteFailed};

/// Mirrors archive.cc:parseDump with RestoreSink: restores the NAR read from
/// `r` at `dest` in `dir`, which must not exist. The byte-exact inverse of
/// `dumpPath`. `r` needs a buffer of `min_reader_buffer` bytes.
pub fn restorePath(io: Io, r: *Io.Reader, dir: Dir, dest: []const u8, d: *Diag) RestoreError!void {
    var p: Parser = .init(r, d);
    try p.consume(&tok_nar, "a NAR header");
    try restoreNode(io, &p, dir, dest, 0);
}

fn restoreNode(io: Io, p: *Parser, parent: Dir, name: []const u8, depth: usize) RestoreError!void {
    if (depth >= max_depth) return p.bad("directory nesting too deep", .{});
    switch (try p.nodeTag()) {
        tag_reg, tag_exe => |tag| {
            const len = try p.regularHead(tag);
            // exclusive: a symlink that is already there must never be written
            // through, and a NAR never names one entry twice
            const f = parent.createFile(io, name, .{ .exclusive = true }) catch |e|
                return p.d.fail(e, "creating file '{s}': {t}", .{ name, e });
            defer f.close(io);
            var fw = f.writerStreaming(io, &.{});
            p.r.streamExact64(&fw.interface, len) catch |e| switch (e) {
                error.EndOfStream => return p.bad("stream ended early", .{}),
                error.ReadFailed => return error.ReadFailed,
                error.WriteFailed => return fw.err orelse error.WriteFailed,
            };
            p.consumed += len;
            try p.padding(len);
            if (tag == tag_exe and File.Permissions.has_executable_bit)
                try f.setPermissions(io, .fromMode(0o755));
        },
        tag_sym => {
            const t = try p.target();
            parent.symLink(io, t, name, .{}) catch |e|
                return p.d.fail(e, "creating symlink '{s}': {t}", .{ name, e });
        },
        else => {
            try p.consume(&tok_dir, "'directory'");
            parent.createDir(io, name, .default_dir) catch |e|
                return p.d.fail(e, "creating directory '{s}': {t}", .{ name, e });
            const sub = try parent.openDir(io, name, .{});
            defer sub.close(io);
            p.openDir(depth);
            while (try p.nextEntry(depth)) |entry| {
                try restoreNode(io, p, sub, entry, depth + 1);
                try p.consume(&tok_par, "')'");
            }
            return;
        },
    }
    try p.consume(&tok_par, "')'");
}

const testing = std.testing;
const path_mod = @import("path.zig");

/// The tree the shell commands in the test comments build:
/// mkdir -p tree/sub; printf 'hello world\n' > tree/a.txt;
/// printf '#!/bin/sh\necho hi\n' > tree/run.sh; chmod +x tree/run.sh;
/// ln -s a.txt tree/link; : > tree/sub/empty; printf zzz > tree/sub/z
/// `exec` is whether `run.sh` has the executable bit.
fn makeTree(exec: bool) !testing.TmpDir {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    errdefer tmp.cleanup();
    try tmp.dir.createDirPath(io, "tree/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/a.txt", .data = "hello world\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/run.sh", .data = "#!/bin/sh\necho hi\n" });
    try tmp.dir.setFilePermissions(io, "tree/run.sh", .fromMode(if (exec) 0o755 else 0o644), .{});
    try tmp.dir.symLink(io, "a.txt", "tree/link", .{});
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/sub/empty", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/sub/z", .data = "zzz" });
    return tmp;
}

fn hashOf(tmp: *testing.TmpDir, sub_path: []const u8) !Hash {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    return narHash(testing.allocator, testing.io, tmp.dir, sub_path, &d);
}

fn expectHex(want: []const u8, h: Hash) !void {
    var buf: [Hash.max_string_len]u8 = undefined;
    try testing.expectEqualStrings(want, h.print(&buf, .base16, false));
}

fn sizeOf(tmp: *testing.TmpDir, sub_path: []const u8) !u64 {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    return (try narHashFiltered(testing.allocator, testing.io, tmp.dir, sub_path, .sha256, keep_all, &d)).size;
}

// nix-store --dump tree | sha256sum ; nix-store --dump tree | wc -c
test "directory NAR" {
    var tmp = try makeTree(false);
    defer tmp.cleanup();
    try expectHex("5bd341428326a5608117fb128d3114fc3fb6c76de99cd19c10397bdad728beae", try hashOf(&tmp, "tree"));
    try testing.expectEqual(1240, try sizeOf(&tmp, "tree"));
    // a trailing slash names the same tree
    try expectHex("5bd341428326a5608117fb128d3114fc3fb6c76de99cd19c10397bdad728beae", try hashOf(&tmp, "tree/"));
}

// the same with `chmod +x tree/run.sh`
test "directory NAR with an executable" {
    if (!File.Permissions.has_executable_bit) return error.SkipZigTest;
    var tmp = try makeTree(true);
    defer tmp.cleanup();
    try expectHex("9db4d4d873838f1fbb8f363841597d61244beebb19bd10b606ae2a6d4b940ede", try hashOf(&tmp, "tree"));
    try testing.expectEqual(1272, try sizeOf(&tmp, "tree"));
}

// nix hash path tree ; nix hash path --base32 tree
test "directory NAR hash formats" {
    var tmp = try makeTree(false);
    defer tmp.cleanup();
    const h = try hashOf(&tmp, "tree");
    var buf: [Hash.max_string_len]u8 = undefined;
    try testing.expectEqualStrings("sha256-W9NBQoMmpWCBF/sSjTEU/D+2x23pnNGcEDl72tcovq4=", h.print(&buf, .sri, false));
    try testing.expectEqualStrings("1bmy53bxlyrr22fd3779dp3vcgzw2hqqs4pv2y0n1996hd143lsv", h.print(&buf, .nix32, false));
}

// nix-store --dump tree/a.txt | sha256sum
test "regular file NAR" {
    var tmp = try makeTree(true);
    defer tmp.cleanup();
    const expected = "34ca3ac63094d1d5751f741101692a78f95eedf10744b088129fc324dfd0f603";
    try expectHex(expected, try hashOf(&tmp, "tree/a.txt"));
    try expectHex(expected, narHashOfString("hello world\n"));
}

// nix-store --dump tree/run.sh | sha256sum
test "script NAR" {
    var tmp = try makeTree(false);
    defer tmp.cleanup();
    try expectHex("e519505edb9f77f7f02efefd3c9b29766fdd0f449e9bf932313d39ce249982e9", try hashOf(&tmp, "tree/run.sh"));
}

// the same after `chmod +x tree/run.sh`
test "executable file NAR" {
    if (!File.Permissions.has_executable_bit) return error.SkipZigTest;
    var tmp = try makeTree(true);
    defer tmp.cleanup();
    try expectHex("5e0accf02cedede5e4119ffa15e79e79a5fb1fb9bc43c3d434f33227a14477a0", try hashOf(&tmp, "tree/run.sh"));
}

// nix-store --dump tree/link | sha256sum
test "symlink NAR" {
    var tmp = try makeTree(true);
    defer tmp.cleanup();
    try expectHex("8d3c00cfa866e4d1b809772afeac240786246221eb2c574d69c4bba168834e81", try hashOf(&tmp, "tree/link"));
}

test "flat hash" {
    var tmp = try makeTree(true);
    defer tmp.cleanup();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const h = try flatHash(testing.io, tmp.dir, "tree/a.txt", .sha256, &d);
    try testing.expect(h.eql(hash_mod.hashBytes(.sha256, "hello world\n")));
    try testing.expectError(error.FileNotFound, flatHash(testing.io, tmp.dir, "tree/nope", .sha256, &d));
}

/// A NAR of one directory holding `names`, each a one-byte file, or of a
/// symlink to `target` when `names` is empty.
fn crafted(buf: []u8, names: []const []const u8, target: []const u8) ![]u8 {
    var w: Io.Writer = .fixed(buf);
    const n: Writer = .{ .w = &w };
    try n.header();
    if (names.len == 0) {
        try n.symlink(target);
    } else {
        try n.dir();
        for (names) |name| {
            try n.entry(name);
            try n.regularBytes(false, "x");
            try n.endEntry();
        }
        try n.endDir();
    }
    return w.buffered();
}

fn parseLen(nar: []const u8, d: *Diag) ReadError!u64 {
    var buf: [min_reader_buffer]u8 = undefined;
    var src: Io.Reader = .fixed(nar);
    var r = src.limited(.unlimited, &buf);
    return parseLength(&r.interface, d);
}

// archive.cc:parse refuses each of these; found by fuzz/ (nar-read)
test "readers refuse what nix refuses" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cases = [_]struct { []const []const u8, []const u8, []const u8 }{
        .{ &.{ "b", "a" }, "", "bad NAR: directory entries out of order" },
        .{ &.{ "a", "a" }, "", "bad NAR: directory entries out of order" },
        .{ &.{".."}, "", "bad NAR: bad entry name" },
        .{ &.{"a/b"}, "", "bad NAR: bad entry name" },
        .{ &.{}, "", "bad NAR: bad symlink target" },
        .{ &.{}, "a\x00b", "bad NAR: bad symlink target" },
    };
    for (cases, 0..) |c, i| {
        var buf: [1024]u8 = undefined;
        const nar = try crafted(&buf, c[0], c[1]);
        try testing.expectError(error.BadNar, parseLen(nar, &d));
        try testing.expectEqualStrings(c[2], d.message());
        var rbuf: [min_reader_buffer]u8 = undefined;
        var src: Io.Reader = .fixed(nar);
        var r = src.limited(.unlimited, &rbuf);
        var name_buf: [16]u8 = undefined;
        const dest = try std.fmt.bufPrint(&name_buf, "out{d}", .{i});
        try testing.expectError(error.BadNar, restorePath(testing.io, &r.interface, tmp.dir, dest, &d));
    }
}

test "readers take a sorted directory" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var buf: [1024]u8 = undefined;
    const nar = try crafted(&buf, &.{ "a", "b" }, "");
    try testing.expectEqual(nar.len, try parseLen(nar, &d));
    try testing.expectError(error.BadNar, parseLen(nar[0 .. nar.len - 24], &d));
    try testing.expectEqualStrings("bad NAR: expected ')'", d.message());
    try testing.expectError(error.BadNar, parseLen(nar[0 .. nar.len - 8], &d));
    try testing.expectEqualStrings("bad NAR: stream ended early", d.message());
}

// nix-store --dump tree | nix-store --restore out ; nix-store --dump out | sha256sum
test "restore round-trip" {
    const io = testing.io;
    var tmp = try makeTree(true);
    defer tmp.cleanup();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var nar: Io.Writer.Allocating = .init(testing.allocator);
    defer nar.deinit();
    try dumpPath(testing.allocator, io, tmp.dir, "tree", &nar.writer, keep_all, &d);
    try testing.expectEqual(nar.written().len, try parseLen(nar.written(), &d));

    var rbuf: [min_reader_buffer]u8 = undefined;
    var src: Io.Reader = .fixed(nar.written());
    var r = src.limited(.unlimited, &rbuf);
    try restorePath(io, &r.interface, tmp.dir, "restored", &d);
    try testing.expect((try hashOf(&tmp, "restored")).eql(try hashOf(&tmp, "tree")));
    var lbuf: [64]u8 = undefined;
    try testing.expectEqualStrings("a.txt", lbuf[0..try tmp.dir.readLink(io, "restored/link", &lbuf)]);
    const exe = (try tmp.dir.statFile(io, "restored/run.sh", .{})).permissions.toMode() & 0o100 != 0;
    try testing.expectEqual(File.Permissions.has_executable_bit, exe);
    try testing.expect((try tmp.dir.statFile(io, "restored/a.txt", .{})).permissions.toMode() & 0o100 == 0);
    // the destination must not exist
    var src2: Io.Reader = .fixed(nar.written());
    var r2 = src2.limited(.unlimited, &rbuf);
    try testing.expectError(error.PathAlreadyExists, restorePath(io, &r2.interface, tmp.dir, "restored", &d));
}

test "restore rejects garbage" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var rbuf: [min_reader_buffer]u8 = undefined;
    var src: Io.Reader = .fixed("nix-archive-2");
    var r = src.limited(.unlimited, &rbuf);
    try testing.expectError(error.BadNar, restorePath(testing.io, &r.interface, tmp.dir, "out", &d));
    try testing.expectEqualStrings("bad NAR: expected a NAR header", d.message());
}

const Seen = struct {
    root_len: usize,
    list: *std.ArrayList(u8),
    skip: ?[]const u8 = null,

    pub fn accept(s: Seen, p: []const u8, t: FileType) Allocator.Error!bool {
        try s.list.print(testing.allocator, "{s}:{s} ", .{ p[s.root_len..], t.nixName() });
        return !std.mem.eql(u8, std.fs.path.basename(p), s.skip orelse return true);
    }
};

test "filter sees types and paths" {
    var tmp = try makeTree(true);
    defer tmp.cleanup();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(testing.allocator);
    _ = try narHashFiltered(testing.allocator, testing.io, tmp.dir, "tree", .sha256, Seen{ .root_len = 5, .list = &seen }, &d);
    try testing.expectEqualStrings("a.txt:regular link:symlink run.sh:regular sub:directory sub/empty:regular sub/z:regular ", seen.items);
}

test "a failing filter fails the dump" {
    var tmp = try makeTree(true);
    defer tmp.cleanup();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const Failing = struct {
        pub fn accept(_: @This(), _: []const u8, _: FileType) error{Boom}!bool {
            return error.Boom;
        }
    };
    try testing.expectError(error.Boom, narHashFiltered(testing.allocator, testing.io, tmp.dir, "tree", .sha256, Failing{}, &d));
    try testing.expectError(error.FileNotFound, narHash(testing.allocator, testing.io, tmp.dir, "nope", &d));
}

// The store paths of the tree, the values Rust iets's store-path tests expect.

fn expectSourcePath(want: []const u8, h: Hash, name: []const u8) !void {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const p = try path_mod.makeFixedOutputPath(.recursive, h, name, &.{}, &d);
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(want, p.print(&buf));
}

// nix-instantiate --eval -E '"${./tree}"'
test "path copy of a directory" {
    var tmp = try makeTree(File.Permissions.has_executable_bit);
    defer tmp.cleanup();
    // Windows has no executable bit, so `run.sh` archives as a plain file
    const want = if (File.Permissions.has_executable_bit) "7achjqw6z8fr92f66lxll1lr3yzpqvc3-tree" else "g0cpk0ypckagh7pql7dvnwl5sjzyc9yi-tree";
    try expectSourcePath("/nix/store/" ++ want, try hashOf(&tmp, "tree"), "tree");
}

// nix-instantiate --eval -E '"${./tree/a.txt}"'
test "path copy of a file" {
    var tmp = try makeTree(true);
    defer tmp.cleanup();
    try expectSourcePath("/nix/store/zwki0nhs1pipypg3dgza58q0vyaa78pl-a.txt", try hashOf(&tmp, "tree/a.txt"), "a.txt");
}

// nix-instantiate --eval -E '"${builtins.filterSource (p: t: baseNameOf p != "sub") ./tree}"'
test "filterSource" {
    var tmp = try makeTree(File.Permissions.has_executable_bit);
    defer tmp.cleanup();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(testing.allocator);
    const r = try narHashFiltered(testing.allocator, testing.io, tmp.dir, "tree", .sha256, Seen{ .root_len = 5, .list = &seen, .skip = "sub" }, &d);
    const want = if (File.Permissions.has_executable_bit) "1rmqvsn4swz7n7vkjyvj6cldipi3gp8b-tree" else "cyq83schjm526jx9m6y2irwmr82abpx5-tree";
    try expectSourcePath("/nix/store/" ++ want, r.hash, "tree");
}

// nix-instantiate --eval -E '"${builtins.path { path = ./tree; name = "mytree"; }}"'
test "path with a name" {
    var tmp = try makeTree(File.Permissions.has_executable_bit);
    defer tmp.cleanup();
    const want = if (File.Permissions.has_executable_bit) "ymkhbrxgqx2ii22w4kqj3jjfmcq5smzk-mytree" else "pj1vdjq68vfa06isb6vvlibb3854wirg-mytree";
    try expectSourcePath("/nix/store/" ++ want, try hashOf(&tmp, "tree"), "mytree");
}

test "a file larger than the read buffer streams whole" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = try testing.allocator.alloc(u8, 300_001);
    defer testing.allocator.free(data);
    for (data, 0..) |*b, i| b.* = @truncate(i *% 31 +% (i >> 9));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "big", .data = data });
    try testing.expect((try hashOf(&tmp, "big")).eql(narHashOfString(data)));
}
