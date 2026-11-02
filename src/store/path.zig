//! Store paths: their names, their validation, and how a hash and a name make
//! one. Mirrors libstore's path.cc and store-dir-config.cc.

const std = @import("std");
const Writer = std.Io.Writer;
const Diag = @import("../diag.zig").Diag;
const hash_mod = @import("hash.zig");
const Hash = hash_mod.Hash;

/// The store directory, which every store path hash takes as input. The
/// command line sets it once, before the first store path is made, from
/// `resolveStoreDir`; everything else only reads it.
pub var store_dir: []const u8 = "/nix/store";

/// Mirrors path.hh:StorePath::HashLen (Nix32 characters).
pub const hash_part_len = 32;

/// Mirrors path.hh:StorePath::MaxPathLen.
pub const max_name_len = 211;

/// The longest base name, `<hash>-<name>`.
pub const max_base_len = hash_part_len + 1 + max_name_len;

pub const drv_extension = ".drv";

pub const Error = error{BadStorePath};

pub const ResolvedStoreDir = struct {
    dir: []const u8,
    /// The override was not absolute, so the default is used. The caller warns
    /// "ignoring NIX_STORE_DIR '<set>', it is not an absolute path".
    ignored: bool = false,
};

/// The store directory from `NIX_STORE_DIR` (or `NIX_STORE`), here `set`, or
/// the host's default: `/nix/store` on Unix and `%PROGRAMDATA%\nix\store` on
/// Windows, as Nix does. A store directory is absolute and has no trailing
/// separator; a Unix one stays valid on Windows, where it hashes like Linux
/// does. The result may live in `buf`.
pub fn resolveStoreDir(buf: []u8, set: ?[]const u8, program_data: ?[]const u8, windows: bool) ResolvedStoreDir {
    const s = set orelse return .{ .dir = defaultStoreDir(buf, program_data, windows) };
    const absolute = std.mem.startsWith(u8, s, "/") or (windows and s.len > 1 and s[1] == ':');
    if (!absolute) return .{ .dir = defaultStoreDir(buf, program_data, windows), .ignored = true };
    var end = s.len;
    while (end > 0 and (s[end - 1] == '/' or (windows and s[end - 1] == '\\'))) end -= 1;
    return .{ .dir = if (end == 0) s[0..1] else s[0..end] };
}

fn defaultStoreDir(buf: []u8, program_data: ?[]const u8, windows: bool) []const u8 {
    if (!windows) return "/nix/store";
    return std.fmt.bufPrint(buf, "{s}\\nix\\store", .{program_data orelse "C:\\ProgramData"}) catch "C:\\ProgramData\\nix\\store";
}

/// What follows `<store dir>/` in `p`.
pub fn stripStoreDir(p: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, p, store_dir)) return null;
    const rest = p[store_dir.len..];
    if (rest.len == 0 or rest[0] != '/') return null;
    return rest[1..];
}

pub const Span = struct { start: usize, len: usize };

/// The first store directory prefix (`<dir>/`) in `text`. Daemon messages name
/// the default directory too, so both it and `store_dir` are matched.
pub fn findStorePrefix(text: []const u8) ?Span {
    var best: ?Span = null;
    const default = "/nix/store/";
    if (std.mem.indexOf(u8, text, default)) |i| best = .{ .start = i, .len = default.len };
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, store_dir)) |at| : (i = at + 1) {
        if (at + store_dir.len < text.len and text[at + store_dir.len] == '/') {
            if (best == null or at < best.?.start) best = .{ .start = at, .len = store_dir.len + 1 };
            break;
        }
    }
    return best;
}

/// Why a name is not a valid store path name, as path.cc:checkName says it.
pub const NameProblem = union(enum) {
    empty,
    too_long: []const u8,
    not_valid: []const u8,
    dot_component: struct { name: []const u8, dots: []const u8 },
    illegal_char: struct { name: []const u8, c: u8 },

    pub fn format(p: NameProblem, w: *Writer) Writer.Error!void {
        switch (p) {
            .empty => try w.writeAll("name must not be empty"),
            .too_long => |n| try w.print("name '{s}' must be no longer than {d} characters", .{ n, max_name_len }),
            .not_valid => |n| try w.print("name '{s}' is not valid", .{n}),
            .dot_component => |x| try w.print("name '{s}' is not valid: first dash-separated component must not be '{s}'", .{ x.name, x.dots }),
            .illegal_char => |x| try w.print("name '{s}' contains illegal character '{c}'", .{ x.name, x.c }),
        }
    }
};

const name_chars: [256]bool = blk: {
    var t: [256]bool = @splat(false);
    for ("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+-._?=") |c| t[c] = true;
    break :blk t;
};

/// Mirrors path.cc:checkName.
/// Why `base` is not a store path's base name, in the order Nix checks:
/// the hash part first. Nix never checks the dash
/// (docs/reference/divergences.md).
pub const BaseProblem = union(enum) {
    too_short,
    bad_hash_char: u8,
    missing_dash,
    name: NameProblem,

    pub fn format(p: BaseProblem, w: *Writer) Writer.Error!void {
        switch (p) {
            .too_short => try w.writeAll("path too short"),
            .bad_hash_char => |c| try w.print("illegal base-32 character '{c}' in the hash part", .{c}),
            .missing_dash => try w.writeAll("missing dash"),
            .name => |n| try n.format(w),
        }
    }
};

pub fn baseProblem(base: []const u8) ?BaseProblem {
    if (base.len < hash_part_len + 1) return .too_short;
    for (base[0..hash_part_len]) |c| if (!hash_mod.isNix32Char(c)) return .{ .bad_hash_char = c };
    if (base[hash_part_len] != '-') return .missing_dash;
    if (nameProblem(base[hash_part_len + 1 ..])) |p| return .{ .name = p };
    return null;
}

pub fn nameProblem(name: []const u8) ?NameProblem {
    if (name.len == 0) return .empty;
    if (name.len > max_name_len) return .{ .too_long = name };
    if (name[0] == '.') {
        if (name.len == 1) return .{ .not_valid = name };
        if (name[1] == '-') return .{ .dot_component = .{ .name = name, .dots = "." } };
        if (name[1] == '.') {
            if (name.len == 2) return .{ .not_valid = name };
            if (name[2] == '-') return .{ .dot_component = .{ .name = name, .dots = ".." } };
        }
    }
    for (name) |c| if (!name_chars[c]) return .{ .illegal_char = .{ .name = name, .c = c } };
    return null;
}

/// Mirrors path.cc:checkName.
pub fn checkName(name: []const u8, d: *Diag) Error!void {
    if (nameProblem(name)) |p| return d.fail(error.BadStorePath, "{f}", .{p});
}

/// A store path held as its base name `<hash>-<name>`, like path.hh:StorePath.
/// A plain value: it owns its bytes, so it needs no allocator.
pub const StorePath = struct {
    len: u8,
    buf: [max_base_len]u8,

    /// Mirrors path.cc:StorePath::StorePath(const Hash &, std::string_view name).
    /// `digest` is the 20-byte compressed hash.
    pub fn init(digest: []const u8, name_: []const u8, d: *Diag) Error!StorePath {
        try checkName(name_, d);
        var p: StorePath = .{ .len = @intCast(hash_part_len + 1 + name_.len), .buf = undefined };
        std.debug.assert(hash_mod.encodeNix32(p.buf[0..hash_part_len], digest).len == hash_part_len);
        p.buf[hash_part_len] = '-';
        @memcpy(p.buf[hash_part_len + 1 ..][0..name_.len], name_);
        return p;
    }

    /// Mirrors path.cc:StorePath::StorePath(std::string_view baseName).
    pub fn fromBaseName(base: []const u8, d: *Diag) Error!StorePath {
        if (baseProblem(base)) |p| return d.fail(error.BadStorePath, "path '{s}' is not a valid store path: {f}", .{ base, p });
        return unchecked(base);
    }

    /// `fromBaseName` for a caller that needs no message: null when `base`
    /// is not a store path's base name.
    pub fn ofBaseName(base: []const u8) ?StorePath {
        if (baseProblem(base) != null) return null;
        return unchecked(base);
    }

    /// `parse` for a caller that needs no message.
    pub fn ofPath(path: []const u8) ?StorePath {
        const rest = stripStoreDir(path) orelse return null;
        if (std.mem.indexOfScalar(u8, rest, '/') != null) return null;
        return ofBaseName(rest);
    }

    fn unchecked(base: []const u8) StorePath {
        var p: StorePath = .{ .len = @intCast(base.len), .buf = undefined };
        @memcpy(p.buf[0..base.len], base);
        return p;
    }

    /// Mirrors store-api.cc:StoreDirConfig::parseStorePath: `<store dir>/<hash>-<name>`.
    pub fn parse(path: []const u8, d: *Diag) Error!StorePath {
        const rest = stripStoreDir(path) orelse
            return d.fail(error.BadStorePath, "path '{s}' is not in the Nix store", .{path});
        if (std.mem.indexOfScalar(u8, rest, '/') != null)
            return d.fail(error.BadStorePath, "path '{s}' is not in the Nix store", .{path});
        return fromBaseName(rest, d);
    }

    pub fn baseName(p: *const StorePath) []const u8 {
        return p.buf[0..p.len];
    }

    pub fn hashPart(p: *const StorePath) []const u8 {
        return p.buf[0..hash_part_len];
    }

    pub fn name(p: *const StorePath) []const u8 {
        return p.buf[hash_part_len + 1 .. p.len];
    }

    /// Mirrors path.hh:StorePath::isDerivation.
    pub fn isDerivation(p: *const StorePath) bool {
        return std.mem.endsWith(u8, p.name(), drv_extension);
    }

    /// The full path `<store dir>/<hash>-<name>` (store-api.cc:printStorePath), for `{f}`.
    pub fn format(p: *const StorePath, w: *Writer) Writer.Error!void {
        try w.writeAll(store_dir);
        try w.writeByte('/');
        try w.writeAll(p.baseName());
    }

    /// The full path in `buf`, which `store_dir.len + 1 + max_base_len` bytes always fit.
    pub fn print(p: *const StorePath, buf: []u8) []u8 {
        var w: Writer = .fixed(buf);
        p.format(&w) catch unreachable;
        return w.buffered();
    }

    pub fn eql(a: *const StorePath, b: *const StorePath) bool {
        return std.mem.eql(u8, a.baseName(), b.baseName());
    }

    /// Store paths order by base name, bytewise, as Nix's do.
    pub fn order(a: *const StorePath, b: *const StorePath) std.math.Order {
        return std.mem.order(u8, a.baseName(), b.baseName());
    }

    pub fn lessThan(_: void, a: StorePath, b: StorePath) bool {
        return a.order(&b) == .lt;
    }
};

/// Sorts `paths` and drops duplicates, as a `std::set<StorePath>` holds them;
/// returns the deduplicated prefix.
pub fn sortUnique(paths: []StorePath) []StorePath {
    std.mem.sortUnstable(StorePath, paths, {}, StorePath.lessThan);
    var n: usize = 0;
    for (paths) |p| {
        if (n > 0 and paths[n - 1].eql(&p)) continue;
        paths[n] = p;
        n += 1;
    }
    return paths[0..n];
}

/// References of a content-addressed path: the union of two sorted, unique
/// lists, so a `.drv` can name its sources and its input derivations together.
pub const Refs = struct {
    a: []const StorePath = &.{},
    b: []const StorePath = &.{},
    self_ref: bool = false,

    /// Mirrors store-dir-config.cc:makeType: each reference appended to the type.
    fn write(r: Refs, w: *Writer) Writer.Error!void {
        var i: usize = 0;
        var j: usize = 0;
        while (i < r.a.len or j < r.b.len) {
            const take_a = j == r.b.len or (i < r.a.len and r.a[i].order(&r.b[j]) != .gt);
            const p = if (take_a) &r.a[i] else &r.b[j];
            if (take_a) {
                if (j < r.b.len and p.eql(&r.b[j])) j += 1;
                i += 1;
            } else j += 1;
            try w.writeByte(':');
            try p.format(w);
        }
        if (r.self_ref) try w.writeAll(":self");
    }

    fn isEmpty(r: Refs) bool {
        return r.a.len == 0 and r.b.len == 0 and !r.self_ref;
    }
};

/// The type string a path hash starts with: its pieces concatenated, then the references.
const Type = struct {
    parts: []const []const u8,
    refs: Refs = .{},
};

/// Mirrors store-dir-config.cc:makeStorePath(type, const Hash &, name). The
/// payload `<type>:<algo>:<base16>:<store dir>:<name>` is streamed into the
/// hasher, so no part of it is allocated.
fn makeFromType(ty: Type, h: Hash, name: []const u8, d: *Diag) Error!StorePath {
    try checkName(name, d);
    var hasher: hash_mod.Hasher = .init(.sha256);
    var buf: [256]u8 = undefined;
    var hw = hasher.writer(&buf);
    const w = &hw.interface;
    writePayload(w, ty, h, name) catch unreachable;
    w.flush() catch unreachable;
    const digest = hash_mod.compress(hasher.finish(), 20);
    return StorePath.init(digest.bytes(), name, d);
}

fn writePayload(w: *Writer, ty: Type, h: Hash, name: []const u8) Writer.Error!void {
    for (ty.parts) |p| try w.writeAll(p);
    try ty.refs.write(w);
    try w.writeByte(':');
    try h.write(w, .base16, true);
    try w.print(":{s}:{s}", .{ store_dir, name });
}

/// Mirrors store-dir-config.cc:makeStorePath(type, const Hash &, name).
pub fn makeStorePath(ty: []const u8, h: Hash, name: []const u8, d: *Diag) Error!StorePath {
    return makeFromType(.{ .parts = &.{ty} }, h, name, d);
}

/// Mirrors derivations.cc:outputPathName: "out" keeps the name, others get
/// `<name>-<id>`. Fails only when `buf` is too small.
pub fn outputPathName(buf: []u8, drv_name: []const u8, output_name: []const u8) error{NoSpaceLeft}![]u8 {
    if (std.mem.eql(u8, output_name, "out")) return std.fmt.bufPrint(buf, "{s}", .{drv_name});
    return std.fmt.bufPrint(buf, "{s}-{s}", .{ drv_name, output_name });
}

/// `outputPathName` into a buffer a valid name always fits; a longer one is the
/// error checkName gives for it.
fn outputName(buf: *[max_name_len]u8, drv_name: []const u8, output_name: []const u8, d: *Diag) Error![]u8 {
    return outputPathName(buf, drv_name, output_name) catch
        d.fail(error.BadStorePath, "name '{s}-{s}' must be no longer than {d} characters", .{ drv_name, output_name, max_name_len });
}

/// Mirrors store-dir-config.cc:makeOutputPath.
pub fn makeOutputPath(output_name: []const u8, h: Hash, drv_name: []const u8, d: *Diag) Error!StorePath {
    var buf: [max_name_len]u8 = undefined;
    const name = try outputName(&buf, drv_name, output_name, d);
    return makeFromType(.{ .parts = &.{ "output:", output_name } }, h, name, d);
}

/// `makeFixedOutputPath` for output `output_name` of derivation `drv_name`
/// (derivations.cc:DerivationOutput::CAFixed::path).
pub fn makeFixedOutputPathFor(method: IngestionMethod, h: Hash, drv_name: []const u8, output_name: []const u8, d: *Diag) Error!StorePath {
    var buf: [max_name_len]u8 = undefined;
    const name = try outputName(&buf, drv_name, output_name, d);
    return makeFixedOutputPath(method, h, name, &.{}, d);
}

/// Mirrors content-address.hh:FileIngestionMethod (Git is not supported).
pub const IngestionMethod = enum {
    flat,
    recursive,
    /// `outputHashMode = "text"`: the output is addressed as `.drv` files and
    /// `builtins.toFile` are. A derivation whose output is itself a `.drv`
    /// needs it, so it is the producer half of a dynamic derivation.
    text,

    /// Mirrors content-address.cc:ContentAddressMethod::renderPrefix.
    pub fn prefix(m: IngestionMethod) []const u8 {
        return switch (m) {
            .flat => "",
            .recursive => "r:",
            .text => "text:",
        };
    }

    /// Mirrors primops.cc:derivationStrict `handleHashMode` ("flat", "recursive", "nar", "text").
    pub fn parse(s: []const u8) ?IngestionMethod {
        const map: std.StaticStringMap(IngestionMethod) = .initComptime(.{
            .{ "flat", .flat },
            .{ "recursive", .recursive },
            .{ "nar", .recursive },
            .{ "text", .text },
        });
        return map.get(s);
    }
};

/// Mirrors store-dir-config.cc:makeFixedOutputPath. `references` is sorted and
/// unique; only recursive sha256 (and text) may carry any.
pub fn makeFixedOutputPath(method: IngestionMethod, h: Hash, name: []const u8, references: []const StorePath, d: *Diag) Error!StorePath {
    if (method == .text) {
        if (h.algo != .sha256)
            return d.fail(error.BadStorePath, "text content address of '{s}' must be sha256, not {s}", .{ name, h.algo.name() });
        return makeTextPath(name, h, .{ .a = references }, d);
    }
    if (h.algo == .sha256 and method == .recursive)
        return makeFromType(.{ .parts = &.{"source"}, .refs = .{ .a = references } }, h, name, d);
    if (references.len > 0)
        return d.fail(error.BadStorePath, "fixed output derivation '{s}' is not allowed to refer to other store paths", .{name});
    return makeStorePath("output:out", fixedOutputInner(method, h), name, d);
}

/// The inner hash of a flat or non-sha256 fixed output: of `fixed:out:<method><algo>:<base16>:`.
fn fixedOutputInner(method: IngestionMethod, h: Hash) Hash {
    var hasher: hash_mod.Hasher = .init(.sha256);
    var buf: [256]u8 = undefined;
    var hw = hasher.writer(&buf);
    const w = &hw.interface;
    w.print("fixed:out:{s}", .{method.prefix()}) catch unreachable;
    h.write(w, .base16, true) catch unreachable;
    w.writeByte(':') catch unreachable;
    w.flush() catch unreachable;
    return hasher.finish();
}

/// Mirrors store-dir-config.cc:makeFixedOutputPathFromCA for TextInfo
/// (builtins.toFile, .drv files). `h` is sha256.
pub fn makeTextPath(name: []const u8, h: Hash, references: Refs, d: *Diag) Error!StorePath {
    std.debug.assert(h.algo == .sha256);
    return makeFromType(.{ .parts = &.{"text"}, .refs = references }, h, name, d);
}

/// Mirrors derivations.cc:hashPlaceholder: the env value of a floating CA
/// output, `/<nix32 of sha256("nix-output:<name>")>`.
pub fn hashPlaceholder(output_name: []const u8) [53]u8 {
    var hasher: hash_mod.Hasher = .init(.sha256);
    hasher.update("nix-output:");
    hasher.update(output_name);
    const h = hasher.finish();
    var out: [53]u8 = undefined;
    out[0] = '/';
    _ = hash_mod.encodeNix32(out[1..], h.bytes());
    return out;
}

const testing = std.testing;

fn expectPath(want: []const u8, p: StorePath) !void {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(want, p.print(&buf));
}

test "the host picks the store directory" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("/nix/store", resolveStoreDir(&buf, null, null, false).dir);
    try testing.expectEqualStrings("D:\\Data\\nix\\store", resolveStoreDir(&buf, null, "D:\\Data", true).dir);
    try testing.expectEqualStrings("C:\\ProgramData\\nix\\store", resolveStoreDir(&buf, null, null, true).dir);
}

test "an override is absolute and has no trailing separator" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("/opt/store", resolveStoreDir(&buf, "/opt/store/", null, false).dir);
    try testing.expectEqualStrings("/", resolveStoreDir(&buf, "/", null, false).dir);
    // a Unix directory stays usable on Windows, where it hashes like Linux
    try testing.expectEqualStrings("/nix/store", resolveStoreDir(&buf, "/nix/store", null, true).dir);
    try testing.expectEqualStrings("E:\\s", resolveStoreDir(&buf, "E:\\s\\", null, true).dir);
    // a relative one is refused
    const r = resolveStoreDir(&buf, "store", null, false);
    try testing.expectEqualStrings("/nix/store", r.dir);
    try testing.expect(r.ignored);
    try testing.expectEqualStrings("/nix/store", resolveStoreDir(&buf, "E:\\s", null, false).dir);
}

test "the directory is found in a path and in text" {
    try testing.expectEqualStrings("abc-x/sub", stripStoreDir("/nix/store/abc-x/sub").?);
    try testing.expectEqual(null, stripStoreDir("/nix/store"));
    try testing.expectEqual(null, stripStoreDir("/nix/storex/a"));
    try testing.expectEqual(null, stripStoreDir("/elsewhere/abc-x"));
    try testing.expectEqual(Span{ .start = 3, .len = 11 }, findStorePrefix("at /nix/store/x").?);
    try testing.expectEqual(null, findStorePrefix("at /nix/store"));
}

// nix-instantiate --eval -E 'builtins.toFile "foo" "bar"'
test "toFile" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const p = try makeTextPath("foo", hash_mod.hashBytes(.sha256, "bar"), .{}, &d);
    try expectPath("/nix/store/vxjiwkjkn7x4079qvh1jkl5pn05j2aw0-foo", p);
    try testing.expectEqualStrings("foo", p.name());
    try testing.expectEqualStrings("vxjiwkjkn7x4079qvh1jkl5pn05j2aw0", p.hashPart());
}

// nix-instantiate --eval -E 'let a = builtins.toFile "a" "x"; in builtins.toFile "b" "ref ${a}"'
test "toFile with a reference" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const a = try makeTextPath("a", hash_mod.hashBytes(.sha256, "x"), .{}, &d);
    try expectPath("/nix/store/12wigjpizrn8axaqxj288q1b751qmwya-a", a);
    var buf: [128]u8 = undefined;
    const contents = try std.fmt.bufPrint(&buf, "ref {f}", .{a});
    const b = try makeTextPath("b", hash_mod.hashBytes(.sha256, contents), .{ .a = &.{a} }, &d);
    try expectPath("/nix/store/kbnsdqvza4r1hzcr5vs2bhx8kv150g37-b", b);
    // the same reference from either list, or both, is the same path
    try testing.expect(b.eql(&try makeTextPath("b", hash_mod.hashBytes(.sha256, contents), .{ .b = &.{a} }, &d)));
    try testing.expect(b.eql(&try makeTextPath("b", hash_mod.hashBytes(.sha256, contents), .{ .a = &.{a}, .b = &.{a} }, &d)));
}

// nix-instantiate --eval --strict -E 'let d = builtins.derivation { name = "fx"; system = "x86_64-linux";
//   builder = "/bin/sh"; outputHash = "ba78...15ad"; outputHashAlgo = "sha256"; }; in d.outPath'
// and for "fr" the same with outputHashMode = "recursive"
test "fixed output path" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const h = try Hash.parseAny("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", .sha256, &d);
    try expectPath("/nix/store/rfn4vzwhmb8r4k8gp16g27dqwjji5s37-fx", try makeFixedOutputPath(.flat, h, "fx", &.{}, &d));
    try expectPath("/nix/store/s05rl80bpix1186wb5f471k7fxwwp7lf-fr", try makeFixedOutputPath(.recursive, h, "fr", &.{}, &d));
}

// the same with outputHash = "a9993e364706816aba3e25717850c26c9cd0d89d"; outputHashAlgo = "sha1"; name "fs1"
test "fixed flat sha1" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const h = try Hash.parseAny("a9993e364706816aba3e25717850c26c9cd0d89d", .sha1, &d);
    try expectPath("/nix/store/nawmi4lnsz5x8kk5pf3j4afk5smhklqr-fs1", try makeFixedOutputPath(.flat, h, "fs1", &.{}, &d));
    const a = try StorePath.parse("/nix/store/12wigjpizrn8axaqxj288q1b751qmwya-a", &d);
    try testing.expectError(error.BadStorePath, makeFixedOutputPath(.flat, h, "fs1", &.{a}, &d));
    try testing.expectEqualStrings("fixed output derivation 'fs1' is not allowed to refer to other store paths", d.message());
    try testing.expectError(error.BadStorePath, makeFixedOutputPath(.text, h, "t", &.{}, &d));
}

test "parse and accessors" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const p = try StorePath.parse("/nix/store/vxjiwkjkn7x4079qvh1jkl5pn05j2aw0-foo.drv", &d);
    try testing.expect(p.isDerivation());
    try testing.expectEqualStrings("foo.drv", p.name());
    try testing.expectEqualStrings("vxjiwkjkn7x4079qvh1jkl5pn05j2aw0-foo.drv", p.baseName());
    try testing.expectError(error.BadStorePath, StorePath.parse("/nix/store/vxjiwkjkn7x4079qvh1jkl5pn05j2aw0-foo/bar", &d));
    try testing.expectEqualStrings("path '/nix/store/vxjiwkjkn7x4079qvh1jkl5pn05j2aw0-foo/bar' is not in the Nix store", d.message());
    try testing.expectError(error.BadStorePath, StorePath.parse("/nix/store/vxjiwkjkn7x4079qvh1jkl5pn05j2aw0foo", &d));
    try testing.expectEqualStrings("path 'vxjiwkjkn7x4079qvh1jkl5pn05j2aw0foo' is not a valid store path: missing dash", d.message());
    try testing.expectError(error.BadStorePath, StorePath.parse("/nix/store/vxjiwkjkn7x4079qvh1jkl5pn05j2awe-foo", &d));
    try testing.expectEqualStrings("path 'vxjiwkjkn7x4079qvh1jkl5pn05j2awe-foo' is not a valid store path: illegal base-32 character 'e' in the hash part", d.message());
    try testing.expectError(error.BadStorePath, StorePath.parse("/tmp/vxjiwkjkn7x4079qvh1jkl5pn05j2aw0-foo", &d));
    try testing.expectError(error.BadStorePath, StorePath.parse("/nix/store/vxjiwkjkn7x4079qvh1jkl5pn05j2aw0-a b", &d));
    try testing.expectEqualStrings("path 'vxjiwkjkn7x4079qvh1jkl5pn05j2aw0-a b' is not a valid store path: name 'a b' contains illegal character ' '", d.message());
}

test "checkName rules" {
    const cases = [_]struct { []const u8, bool }{
        .{ "hello-2.12", true },
        .{ "a+b_c?d=e.f", true },
        .{ ".hidden", true },
        .{ "..x", true },
        .{ "", false },
        .{ ".", false },
        .{ "..", false },
        .{ ".-x", false },
        .{ "..-x", false },
        .{ "a b", false },
        .{ "a/b", false },
        .{ &@as([211]u8, @splat('a')), true },
        .{ &@as([212]u8, @splat('a')), false },
    };
    for (cases) |c| try testing.expectEqual(c[1], nameProblem(c[0]) == null);
}

test "output names" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("hello", try outputPathName(&buf, "hello", "out"));
    try testing.expectEqualStrings("hello-dev", try outputPathName(&buf, "hello", "dev"));
}

// nix-instantiate --eval -E 'builtins.placeholder "out"'
test "placeholder" {
    try testing.expectEqualStrings("/1rz4g4znpzjwh1xymhjpm42vipw92pr73vdgl6xs1hycac8kf2n9", &hashPlaceholder("out"));
}

test "a multibyte char across the hash part is an error" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    try testing.expectError(error.BadStorePath, StorePath.parse("/nix/store/" ++ @as([31]u8, @splat('a')) ++ "é-x", &d));
}
