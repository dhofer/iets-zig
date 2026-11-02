//! Framing of the Nix worker protocol (libutil/serialise.hh): every integer is
//! a u64 in little-endian; a string is its length, its bytes, and zero padding
//! to a multiple of 8.
//!
//! A read fails with `error.Io` and a message in the `Diag`: "worker
//! protocol: ..." for data Nix's client refuses too, and the stream's own
//! text for a short read. A reply string is allocated in the caller's arena.

const std = @import("std");
const text = @import("../../syntax/text.zig");
const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;
const Allocator = std.mem.Allocator;
const Diag = @import("../../diag.zig").Diag;
const remote = @import("../../remote.zig");
const hash_mod = @import("../../store/hash.zig");
const Hash = hash_mod.Hash;
const nar = @import("../../store/nar.zig");
const path_mod = @import("../../store/path.zig");
const StorePath = path_mod.StorePath;
const plan = @import("../plan.zig");
const Object = plan.Object;

pub const ReadError = error{ Io, OutOfMemory };

pub fn writeU64(w: *Writer, n: u64) Writer.Error!void {
    return w.writeInt(u64, n, .little);
}

pub fn writeStr(w: *Writer, s: []const u8) Writer.Error!void {
    try writeU64(w, s.len);
    try w.writeAll(s);
    const rem = s.len % 8;
    if (rem != 0) try w.splatByteAll(0, 8 - rem);
}

/// Mirrors serialise.cc:writeStrings: a count followed by each string.
pub fn writeStrs(w: *Writer, items: []const []const u8) Writer.Error!void {
    try writeU64(w, items.len);
    for (items) |s| try writeStr(w, s);
}

/// `writeStrs` of full store paths.
pub fn writePaths(w: *Writer, items: []const StorePath) Writer.Error!void {
    try writeU64(w, items.len);
    var buf: [path_mod.max_base_len + 256]u8 = undefined;
    for (items) |*p| try writeStr(w, p.print(&buf));
}

fn bad(d: *Diag, comptime why: []const u8, args: anytype) error{Io} {
    return d.fail(error.Io, "worker protocol: " ++ why, args);
}

/// A failed read, in the words Rust iets prints for it.
pub fn readFailed(d: *Diag, e: Reader.Error) error{Io} {
    return d.fail(error.Io, "{s}", .{switch (e) {
        error.EndOfStream => "failed to fill whole buffer",
        error.ReadFailed => "read failed",
    }});
}

pub fn readU64(r: *Reader, d: *Diag) ReadError!u64 {
    return r.takeInt(u64, .little) catch |e| readFailed(d, e);
}

fn skipPadding(r: *Reader, len: u64, d: *Diag) ReadError!void {
    const rem: usize = @intCast(len % 8);
    if (rem == 0) return;
    const pad = r.take(8 - rem) catch |e| return readFailed(d, e);
    for (pad) |b| if (b != 0) return bad(d, "non-zero padding", .{});
}

/// Mirrors serialise.cc:readString with a size cap.
pub fn readBytes(r: *Reader, arena: Allocator, max: u64, d: *Diag) ReadError![]u8 {
    const len = try readU64(r, d);
    if (len > max) return bad(d, "string too long", .{});
    const buf = try arena.alloc(u8, @intCast(len));
    r.readSliceAll(buf) catch |e| return readFailed(d, e);
    try skipPadding(r, len, d);
    return buf;
}

/// A string the caller only looks at: valid until the next read, when it
/// fits the reader's buffer; longer ones go to `arena`.
pub fn peekBytes(r: *Reader, arena: Allocator, max: u64, d: *Diag) ReadError![]const u8 {
    const len = try readU64(r, d);
    if (len > max) return bad(d, "string too long", .{});
    const padded = std.mem.alignForward(u64, len, 8);
    if (padded <= r.buffer.len) {
        const all = r.take(@intCast(padded)) catch |e| return readFailed(d, e);
        for (all[@intCast(len)..]) |b| if (b != 0) return bad(d, "non-zero padding", .{});
        return all[0..@intCast(len)];
    }
    const buf = try arena.alloc(u8, @intCast(len));
    r.readSliceAll(buf) catch |e| return readFailed(d, e);
    try skipPadding(r, len, d);
    return buf;
}

pub fn skipBytes(r: *Reader, max: u64, d: *Diag) ReadError!void {
    const len = try readU64(r, d);
    if (len > max) return bad(d, "string too long", .{});
    r.discardAll64(std.mem.alignForward(u64, len, 8)) catch |e| return readFailed(d, e);
}

pub const max_string: u64 = 64 << 20;

pub fn readStr(r: *Reader, arena: Allocator, d: *Diag) ReadError![]const u8 {
    return text.lossyAlloc(arena, try readBytes(r, arena, max_string, d));
}

pub fn readStrs(r: *Reader, arena: Allocator, d: *Diag) ReadError![][]const u8 {
    const n = try readU64(r, d);
    if (n > 1 << 24) return bad(d, "string list too long", .{});
    const out = try arena.alloc([]const u8, @intCast(n));
    for (out) |*s| s.* = try readStr(r, arena, d);
    return out;
}

/// `serialise.hh:readNum<bool>`: 0 or 1, nothing else.
pub fn readBool(r: *Reader, d: *Diag) ReadError!bool {
    return switch (try readU64(r, d)) {
        0 => false,
        1 => true,
        else => |n| bad(d, "serialised integer {d} is too large for a boolean", .{n}),
    };
}

/// serialise.hh:readNum<time_t>: a signed 64-bit integer.
pub fn readTime(r: *Reader, d: *Diag) ReadError!u64 {
    const n = try readU64(r, d);
    if (n > std.math.maxInt(i64)) return bad(d, "serialised integer {d} is too large for a time", .{n});
    return n;
}

/// `serialise.hh:readNum<T>`: a number no larger than `T` holds.
pub fn readNum(r: *Reader, max: u64, d: *Diag) ReadError!u64 {
    const n = try readU64(r, d);
    if (n > max) return bad(d, "serialised integer {d} is too large", .{n});
    return n;
}

fn checkPath(s: []const u8, d: *Diag) error{Io}!void {
    _ = StorePath.parse(s, d) catch {
        remote.prefix(d, "worker protocol", .{});
        return error.Io;
    };
}

/// `worker-protocol.cc:Serialise<StorePath>`: the daemon names a store path,
/// and what is not one is an error, not a path for this client to act on.
pub fn readPath(r: *Reader, arena: Allocator, d: *Diag) ReadError![]const u8 {
    const s = try readStr(r, arena, d);
    try checkPath(s, d);
    return s;
}

/// `Serialise<std::optional<StorePath>>`: the empty string is none.
pub fn readOptPath(r: *Reader, arena: Allocator, d: *Diag) ReadError![]const u8 {
    const s = try readStr(r, arena, d);
    if (s.len > 0) try checkPath(s, d);
    return s;
}

/// `Serialise<StorePathSet>`.
pub fn readPaths(r: *Reader, arena: Allocator, d: *Diag) ReadError![][]const u8 {
    const v = try readStrs(r, arena, d);
    for (v) |s| try checkPath(s, d);
    return v;
}

/// `Serialise<StorePath>`, parsed: nothing is allocated for a path.
pub fn readStorePath(r: *Reader, arena: Allocator, d: *Diag) ReadError!StorePath {
    const s = try peekBytes(r, arena, max_string, d);
    if (StorePath.ofPath(s)) |p| return p;
    // the message names the path as `readPath` does, lossily decoded
    return StorePath.parse(try text.lossyAlloc(arena, s), d) catch {
        remote.prefix(d, "worker protocol", .{});
        return error.Io;
    };
}

/// `Serialise<StorePathSet>`, parsed.
pub fn readStorePaths(r: *Reader, arena: Allocator, d: *Diag) ReadError![]StorePath {
    const n = try readU64(r, d);
    if (n > 1 << 24) return bad(d, "string list too long", .{});
    // the count is the peer's word, so the list grows with what arrives
    var out: std.ArrayList(StorePath) = try .initCapacity(arena, @min(n, 1 << 10));
    for (0..@intCast(n)) |_| try out.append(arena, try readStorePath(r, arena, d));
    return out.items;
}

/// `Serialise<UnkeyedValidPathInfo>`'s NAR hash: `Hash::parseAny` for
/// SHA-256, in any of its forms, held as the base16 the protocol writes.
pub fn narHash(arena: Allocator, s: []const u8, d: *Diag) ReadError![]u8 {
    const h = Hash.parseAny(s, .sha256, d) catch {
        remote.prefix(d, "worker protocol", .{});
        return error.Io;
    };
    return h.alloc(arena, .base16, false);
}

/// local-keys.cc:parseColonBase64: a key name, a colon and non-empty base64,
/// held as Signature::to_string writes it: the bytes encoded again, so a
/// newline or what follows `=` in the reply is gone.
pub fn signature(arena: Allocator, s: []const u8, d: *Diag) ReadError![]u8 {
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return bad(d, "signature is corrupt", .{});
    const name = s[0..colon];
    if (name.len == 0) return bad(d, "signature is corrupt", .{});
    var scratch: Diag = .init(d.gpa);
    defer scratch.deinit();
    const raw = hash_mod.decodeBase64Alloc(arena, s[colon + 1 ..], &scratch) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => bad(d, "signature is corrupt", .{}),
    };
    if (raw.len == 0) return bad(d, "signature is corrupt", .{});
    var out: Writer.Allocating = .init(arena);
    out.writer.print("{s}:", .{name}) catch return error.OutOfMemory;
    hash_mod.writeBase64(&out.writer, raw) catch return error.OutOfMemory;
    return out.written();
}

/// content-address.cc:ContentAddress::parseOpt: empty, `text:ALGO:HASH`, or
/// `fixed:[r:]ALGO:HASH`, held as renderContentAddress writes it (the hash in
/// nix32). `fixed:git:` needs the git-hashing experimental feature, which a
/// client has not got by default.
pub fn contentAddress(arena: Allocator, s: []const u8, d: *Diag) ReadError![]u8 {
    if (s.len == 0) return &.{};
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return bad(d, "'{s}' is not a content address", .{s});
    var method: []const u8 = undefined;
    var rest = s[colon + 1 ..];
    if (std.mem.eql(u8, s[0..colon], "text")) {
        method = "text:";
    } else if (std.mem.eql(u8, s[0..colon], "fixed")) {
        if (std.mem.startsWith(u8, rest, "r:")) {
            method = "fixed:r:";
            rest = rest[2..];
        } else method = "fixed:";
    } else return bad(d, "'{s}' is not a content address", .{s});
    const c2 = std.mem.indexOfScalar(u8, rest, ':') orelse return bad(d, "'{s}' is not a content address", .{s});
    const algo_s = rest[0..c2];
    const algo = hash_mod.Algo.parse(algo_s) orelse return bad(d, "unknown hash algorithm '{s}'", .{algo_s});
    const h = Hash.parseNonSriUnprefixed(rest[c2 + 1 ..], algo, d) catch {
        remote.prefix(d, "worker protocol", .{});
        return error.Io;
    };
    var buf: [Hash.max_string_len]u8 = undefined;
    return std.fmt.allocPrint(arena, "{s}{s}:{s}", .{ method, algo.name(), h.print(&buf, .nix32, false) });
}

/// derived-path.cc:DerivedPath::parseLegacy without dynamic derivations:
/// `PATH`, `PATH!*` or `PATH!NAME,...`, held as to_string_legacy writes it,
/// with the names sorted and each once.
pub fn derivedPath(arena: Allocator, s: []const u8, d: *Diag) ReadError![]u8 {
    const bang = std.mem.lastIndexOfScalar(u8, s, '!') orelse {
        try checkPath(s, d);
        return arena.dupe(u8, s);
    };
    const drv = s[0..bang];
    const outputs = s[bang + 1 ..];
    if (std.mem.indexOfScalar(u8, drv, '!') != null)
        return bad(d, "'{s}' builds an output of a derivation output, which needs dynamic-derivations", .{s});
    try checkPath(drv, d);
    if (std.mem.eql(u8, outputs, "*")) return arena.dupe(u8, s);
    var names: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, outputs, ',');
    while (it.next()) |n| {
        path_mod.checkName(n, d) catch {
            remote.prefix(d, "worker protocol", .{});
            return error.Io;
        };
        try names.append(arena, n);
    }
    std.mem.sortUnstable([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, drv);
    try out.append(arena, '!');
    for (names.items, 0..) |n, i| {
        if (i > 0 and std.mem.eql(u8, n, names.items[i - 1])) continue;
        if (i > 0) try out.append(arena, ',');
        try out.appendSlice(arena, n);
    }
    return out.items;
}

/// realisation.cc:DrvOutput::parse: a prefixed hash, `!`, an output name
/// that is not checked.
pub fn drvOutput(s: []const u8, d: *Diag) ReadError!void {
    const bang = std.mem.indexOfScalar(u8, s, '!') orelse return bad(d, "invalid derivation output id {s}", .{s});
    _ = Hash.parseAny(s[0..bang], null, d) catch {
        remote.prefix(d, "worker protocol", .{});
        return error.Io;
    };
}

/// `common-protocol.cc:Serialise<Realisation>`: the JSON of realisation.cc,
/// `outPath` a store path's base name, `signatures` if there, and `id`.
pub fn realisation(gpa: Allocator, raw: []const u8, d: *Diag) ReadError!void {
    const pre = "worker protocol: while parsing a realisation object: ";
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, raw, .{}) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => d.fail(error.Io, pre ++ "{t}", .{e}),
    };
    defer parsed.deinit();
    const o = switch (parsed.value) {
        .object => |o| o,
        else => return d.fail(error.Io, pre ++ "not an object", .{}),
    };
    const string = struct {
        fn f(obj: std.json.ObjectMap, key: []const u8, dd: *Diag) ReadError![]const u8 {
            const v = obj.get(key) orelse return dd.fail(error.Io, pre ++ "no key '{s}'", .{key});
            return switch (v) {
                .string => |s| s,
                else => dd.fail(error.Io, pre ++ "'{s}' is not a string", .{key}),
            };
        }
    }.f;
    _ = StorePath.fromBaseName(try string(o, "outPath", d), d) catch {
        remote.prefix(d, "worker protocol", .{});
        return error.Io;
    };
    if (o.get("signatures")) |sigs| {
        const list = switch (sigs) {
            .array => |a| a,
            else => return d.fail(error.Io, pre ++ "'signatures' is not a list", .{}),
        };
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        for (list.items) |s| switch (s) {
            .string => |str| _ = try signature(scratch.allocator(), str, d),
            else => return d.fail(error.Io, pre ++ "a signature is not a string", .{}),
        };
    }
    return drvOutput(try string(o, "id", d), d);
}

/// Mirrors serialise.hh:FramedSink: the payload of `AddMultipleToStore` goes
/// out as length-prefixed frames (no padding) closed by a zero-length frame,
/// so the daemon can find the end without parsing the content. The frame is
/// the writer's buffer.
pub const FramedSink = struct {
    to: *Writer,
    interface: Writer,

    pub const frame = 1 << 20;

    pub fn init(to: *Writer, buf: []u8) FramedSink {
        return .{ .to = to, .interface = .{ .buffer = buf, .vtable = &.{ .drain = drain, .flush = flush } } };
    }

    fn send(s: *FramedSink, data: []const u8) Writer.Error!void {
        if (data.len == 0) return;
        try writeU64(s.to, data.len);
        try s.to.writeAll(data);
    }

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const s: *FramedSink = @fieldParentPtr("interface", w);
        try s.send(w.buffered());
        w.end = 0;
        if (data.len == 1 and splat == 0) return 0;
        // a write as large as a frame goes out as its own frame, uncopied
        const first = data[0];
        if (first.len >= w.buffer.len) {
            try s.send(first);
            return first.len;
        }
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |b| {
            if (w.end + b.len > w.buffer.len) return n;
            @memcpy(w.buffer[w.end..][0..b.len], b);
            w.end += b.len;
            n += b.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            if (w.end + last.len > w.buffer.len) return n;
            @memcpy(w.buffer[w.end..][0..last.len], last);
            w.end += last.len;
            n += last.len;
        }
        return n;
    }

    fn flush(w: *Writer) Writer.Error!void {
        const s: *FramedSink = @fieldParentPtr("interface", w);
        try s.send(w.buffered());
        w.end = 0;
        try s.to.flush();
    }

    /// Sends the last frame and the terminator.
    pub fn finish(s: *FramedSink) Writer.Error!void {
        try s.send(s.interface.buffered());
        s.interface.end = 0;
        try writeU64(s.to, 0);
        try s.to.flush();
    }
};

/// Counts the bytes that pass through on their way to `inner`.
pub const Counting = struct {
    inner: *Writer,
    bytes: u64 = 0,
    interface: Writer,

    pub fn init(inner: *Writer, buf: []u8) Counting {
        return .{ .inner = inner, .interface = .{ .buffer = buf, .vtable = &.{ .drain = drain, .flush = flush } } };
    }

    /// Everything written so far, buffered or not.
    pub fn count(c: *const Counting) u64 {
        return c.bytes + c.interface.end;
    }

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const c: *Counting = @fieldParentPtr("interface", w);
        const b = w.buffered();
        try c.inner.writeAll(b);
        c.bytes += b.len;
        w.end = 0;
        const n = try c.inner.writeSplat(data, splat);
        c.bytes += n;
        return n;
    }

    fn flush(w: *Writer) Writer.Error!void {
        const c: *Counting = @fieldParentPtr("interface", w);
        const b = w.buffered();
        try c.inner.writeAll(b);
        c.bytes += b.len;
        w.end = 0;
        try c.inner.flush();
    }
};

pub const ObjectError = error{ Io, Store, OutOfMemory, WriteFailed };

/// One `ValidPathInfo` (worker-protocol.cc, the 1.16 layout
/// `addMultipleToStore` fixes) and the NAR after it. Registration time 0 and
/// no signatures: the daemon recomputes the content address and accepts the
/// path on that alone.
pub fn writeObject(gpa: Allocator, io: Io, w: *Writer, o: *const Object, d: *Diag) ObjectError!void {
    var pbuf: [path_mod.max_base_len + 256]u8 = undefined;
    var hbuf: [Hash.max_string_len]u8 = undefined;
    var cbuf: [Hash.max_string_len + 32]u8 = undefined;
    switch (o.*) {
        .source => |*s| {
            var refs: []const StorePath = &.{};
            const ca = switch (s.kind) {
                .source => std.fmt.bufPrint(&cbuf, "fixed:r:sha256:{s}", .{s.nar_hash.print(&hbuf, .nix32, false)}),
                .flat => |h| std.fmt.bufPrint(&cbuf, "fixed:{s}:{s}", .{ h.algo.name(), h.print(&hbuf, .nix32, false) }),
                .text => |r| blk: {
                    refs = r;
                    const flat = switch (s.at.src) {
                        .mem => |contents| hash_mod.hashBytes(.sha256, contents),
                        .fs => fs: {
                            var arena: std.heap.ArenaAllocator = .init(gpa);
                            defer arena.deinit();
                            const local = (try s.at.local(arena.allocator())).?;
                            break :fs nar.flatHash(io, Io.Dir.cwd(), local, .sha256, d) catch |e|
                                return remote.failIo(d, e, "hashing '{s}'", .{local});
                        },
                        // a text is held in memory; a fetched input is no text
                        .spool => return d.fail(error.Store, "text source '{f}' is not held in memory", .{&s.path}),
                    };
                    break :blk std.fmt.bufPrint(&cbuf, "text:sha256:{s}", .{flat.print(&hbuf, .nix32, false)});
                },
            } catch unreachable;
            var nbuf: [Hash.max_string_len]u8 = undefined;
            try writeInfo(w, s.path.print(&pbuf), s.nar_hash.print(&nbuf, .base16, false), refs, s.nar_size, ca);
            // The framed body declares `nar_size` before the bytes, so a tree
            // that changed after evaluation must fail here rather than
            // desynchronise the stream.
            var buf: [1 << 16]u8 = undefined;
            var counted: Counting = .init(w, &buf);
            s.at.nar(gpa, io, &counted.interface, d) catch |e| return switch (e) {
                error.WriteFailed => error.WriteFailed,
                error.OutOfMemory => error.OutOfMemory,
                else => if (d.msg != null) error.Io else remote.failIo(d, e, "dumping '{f}'", .{&s.path}),
            };
            if (counted.bytes != s.nar_size)
                return d.fail(error.Io, "source '{f}' changed since evaluation: its NAR is {d} bytes, not {d}", .{ &s.path, counted.bytes, s.nar_size });
        },
        .drv => |*v| {
            const h = v.getHashes();
            var nbuf: [Hash.max_string_len]u8 = undefined;
            const ca = std.fmt.bufPrint(&cbuf, "text:sha256:{s}", .{h.text.print(&hbuf, .nix32, false)}) catch unreachable;
            try writeInfo(w, v.path.print(&pbuf), h.nar_hash.print(&nbuf, .base16, false), v.references, h.nar_size, ca);
            try nar.dumpString(v.aterm, w);
        },
    }
}

fn writeInfo(w: *Writer, path: []const u8, nar_hash_base16: []const u8, references: []const StorePath, nar_size: u64, ca: []const u8) Writer.Error!void {
    try writeStr(w, path);
    try writeStr(w, "");
    try writeStr(w, nar_hash_base16);
    try writePaths(w, references);
    try writeU64(w, 0);
    try writeU64(w, nar_size);
    try writeU64(w, 0);
    try writeStrs(w, &.{});
    try writeStr(w, ca);
}

// Tests

const testing = std.testing;

fn enc(buf: []u8, s: []const u8) []u8 {
    var w: Writer = .fixed(buf);
    writeStr(&w, s) catch unreachable;
    return w.buffered();
}

fn num(buf: *[8]u8, n: u64) []u8 {
    std.mem.writeInt(u64, buf, n, .little);
    return buf;
}

test "strings are padded" {
    var buf: [64]u8 = undefined;
    const out = enc(&buf, "hello");
    try testing.expectEqual(16, out.len);
    try testing.expectEqual(5, std.mem.readInt(u64, out[0..8], .little));
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, out[13..]);
    var r: Reader = .fixed(out);
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const s = try readStr(&r, testing.allocator, &d);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("hello", s);
    try testing.expectEqual(0, r.bufferedLen());
}

test "framed sink frames and terminates" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var fbuf: [64]u8 = undefined;
    var s: FramedSink = .init(&out.writer, &fbuf);
    try s.interface.writeAll("abc");
    try s.interface.writeAll("de");
    try s.finish();
    var expect: [8 + 5 + 8]u8 = undefined;
    std.mem.writeInt(u64, expect[0..8], 5, .little);
    @memcpy(expect[8..13], "abcde");
    std.mem.writeInt(u64, expect[13..21], 0, .little);
    try testing.expectEqualSlices(u8, &expect, out.written());
}

test "a large write is its own frame" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var fbuf: [8]u8 = undefined;
    var s: FramedSink = .init(&out.writer, &fbuf);
    try s.interface.writeAll("ab");
    try s.interface.writeAll("0123456789");
    try s.finish();
    const o = out.written();
    try testing.expectEqual(2, std.mem.readInt(u64, o[0..8], .little));
    try testing.expectEqualStrings("ab", o[8..10]);
    try testing.expectEqual(10, std.mem.readInt(u64, o[10..18], .little));
    try testing.expectEqualStrings("0123456789", o[18..28]);
    try testing.expectEqual(0, std.mem.readInt(u64, o[28..36], .little));
}

fn rd(bytes: []const u8) Reader {
    return .fixed(bytes);
}

// what Nix 2.34.8's client refuses in a reply, found by fuzz/ (wire)
test "replies are read as nix reads them" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var b: [256]u8 = undefined;
    var n: [8]u8 = undefined;
    var r = rd(enc(&b, "/etc/passwd"));
    try testing.expectError(error.Io, readPath(&r, a, &d));
    r = rd(enc(&b, "/nix/store/not-a-store-path"));
    try testing.expectError(error.Io, readPath(&r, a, &d));
    r = rd(enc(&b, ""));
    _ = try readOptPath(&r, a, &d);
    r = rd(num(&n, 2));
    try testing.expectError(error.Io, readBool(&r, &d));
    r = rd(num(&n, std.math.maxInt(u64)));
    try testing.expectError(error.Io, readTime(&r, &d));
    const hex = "4ab29c33e1fd9f3e3e1ebf6e0da0e8f8c3a5e3a73c92c4e9d6e8c04b1a5f2b3d";
    try testing.expectEqualStrings(hex, try narHash(a, "sha256:" ++ hex, &d));
    try testing.expectError(error.Io, narHash(a, "abc", &d));
    try testing.expectEqualStrings("cache.nixos.org-1:dGVzdA==", try signature(a, "cache.nixos.org-1:dGVz\ndA==junk", &d));
    try testing.expectError(error.Io, signature(a, "no-colon", &d));
    try testing.expectError(error.Io, signature(a, ":dGVzdA==", &d));
    try testing.expectEqualStrings(
        "text:sha256:0g9bbwd4ph78svlw94iwlzisbhzqx2h0svmz3qz3x7zxw4rrrcja",
        try contentAddress(a, "text:sha256:" ++ hex, &d),
    );
    _ = try contentAddress(a, "fixed:r:sha256:" ++ hex, &d);
    try testing.expectError(error.Io, contentAddress(a, "fixed:git:sha1:" ++ hex, &d));
    try testing.expectError(error.Io, contentAddress(a, "nonsense", &d));
}

test "build results are read as nix reads them" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const drv = "/nix/store/7q6r5bxprr5bzxqyhjmzjvcg9c0sfbyk-a.drv";
    try testing.expectEqualStrings(drv ++ "!dev,out", try derivedPath(a, drv ++ "!out,dev,out", &d));
    try testing.expectEqualStrings(drv ++ "!*", try derivedPath(a, drv ++ "!*", &d));
    _ = try derivedPath(a, drv, &d);
    try testing.expectError(error.Io, derivedPath(a, drv ++ "!out!bin", &d));
    try testing.expectError(error.Io, derivedPath(a, drv ++ "!", &d));
    try testing.expectError(error.Io, derivedPath(a, "/etc/passwd!out", &d));
    const hex = "4ab29c33e1fd9f3e3e1ebf6e0da0e8f8c3a5e3a73c92c4e9d6e8c04b1a5f2b3d";
    try drvOutput("sha256:" ++ hex ++ "!out", &d);
    try testing.expectError(error.Io, drvOutput(hex ++ "!out", &d));
    const out = "0c6ld7f4z8xbwgaz1mqk5c5bkwlhypzb-hello-2.12.3";
    const id = "sha256:" ++ hex ++ "!out";
    try realisation(testing.allocator, "{\"id\":\"" ++ id ++ "\",\"outPath\":\"" ++ out ++ "\",\"signatures\":[\"k:dGVzdA==\"]}", &d);
    try testing.expectError(error.Io, realisation(testing.allocator, "{\"id\":\"" ++ id ++ "\",\"outPath\":\"" ++ out ++ "\",\"signatures\":null}", &d));
    try testing.expectError(error.Io, realisation(testing.allocator, "{\"id\":\"" ++ id ++ "\",\"outPath\":\"/nix/store/" ++ out ++ "\"}", &d));
    try testing.expectError(error.Io, realisation(testing.allocator, "[]", &d));
    var n: [8]u8 = undefined;
    var r = rd(num(&n, 256));
    try testing.expectError(error.Io, readNum(&r, std.math.maxInt(u8), &d));
}

test "invalid UTF-8 reads as Rust's from_utf8_lossy" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var s = "a\xffb\xe2\x82".*;
    try testing.expectEqualStrings("a\u{FFFD}b\u{FFFD}", try text.lossyAlloc(arena_state.allocator(), &s));
}

test "a drv object is its info and its NAR" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const p = try StorePath.parse("/nix/store/7q6r5bxprr5bzxqyhjmzjvcg9c0sfbyk-a.drv", &d);
    const o: Object = .drvObject(p, "Derive()", &.{});
    try writeObject(testing.allocator, testing.io, &out.writer, &o, &d);
    var r: Reader = .fixed(out.written());
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("/nix/store/7q6r5bxprr5bzxqyhjmzjvcg9c0sfbyk-a.drv", try readStr(&r, a, &d));
    try testing.expectEqualStrings("", try readStr(&r, a, &d));
    _ = try readStr(&r, a, &d);
    try testing.expectEqual(0, (try readStrs(&r, a, &d)).len);
    try testing.expectEqual(0, try readU64(&r, &d));
    const size = try readU64(&r, &d);
    try testing.expectEqual(0, try readU64(&r, &d));
    try testing.expectEqual(0, (try readStrs(&r, a, &d)).len);
    try testing.expect(std.mem.startsWith(u8, try readStr(&r, a, &d), "text:sha256:"));
    try testing.expectEqual(size, r.bufferedLen());
}
