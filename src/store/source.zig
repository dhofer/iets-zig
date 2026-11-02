//! Where the bytes of a path are, and where an input source came from during
//! evaluation. The remote client ships sources from these records, so it
//! never needs a local store.
//!
//! An entry of the input store is held open here rather than opened on
//! first read. A tracing-cache hit that only uploads runs no evaluation, so
//! a `build` hit opens the entries its source table names when it decodes
//! the table (`trace.wire.decodeSources`).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Diag = @import("../diag.zig").Diag;
const Hash = @import("hash.zig").Hash;
const StorePath = @import("path.zig").StorePath;
const nar_mod = @import("nar.zig");
const treestore = @import("../treestore.zig");

/// Absolute paths on disk a filter kept.
pub const PathSet = std.StringHashMapUnmanaged(void);

/// What holds the bytes (source-accessor.hh:SourceAccessor).
pub const Src = union(enum) {
    /// A directory on disk, or any path of the real file system as its own
    /// root. `accepted` holds every entry a tree filter kept: an entry it
    /// left out does not exist (filtering-source-accessor.hh).
    fs: struct { root: []const u8, accepted: ?*const PathSet = null },
    /// One regular file: a `toFile` text or a `.drv` this evaluation holds.
    mem: []const u8,
    /// An entry of the user-level input store (`treestore.zig`), by store
    /// path base name: a fetched input, served out of the store's packs.
    /// `accepted` is as for `fs`, with each member named by its path in the
    /// entry under `/` (`inSpool`).
    spool: struct { name: []const u8, tree: *const treestore.StoredTree, accepted: ?*const PathSet = null },
};

/// A path inside a `Src` (source-path.hh:SourcePath). `rel` has no leading
/// `/` and is empty for the root.
pub const SrcPath = struct {
    src: Src,
    rel: []const u8 = "",

    pub fn fs(root: []const u8, accepted: ?*const PathSet) SrcPath {
        return .{ .src = .{ .fs = .{ .root = root, .accepted = accepted } } };
    }

    pub fn mem(contents: []const u8) SrcPath {
        return .{ .src = .{ .mem = contents } };
    }

    pub fn spool(name: []const u8, tree: *const treestore.StoredTree, accepted: ?*const PathSet, rel: []const u8) SrcPath {
        return .{ .src = .{ .spool = .{ .name = name, .tree = tree, .accepted = accepted } }, .rel = rel };
    }

    /// The path on disk, when the bytes are on disk; allocated in `arena`.
    pub fn local(sp: SrcPath, arena: Allocator) Allocator.Error!?[]const u8 {
        return switch (sp.src) {
            .fs => |f| if (sp.rel.len == 0) f.root else try std.fs.path.join(arena, &.{ f.root, sp.rel }),
            .mem, .spool => null,
        };
    }

    /// Writes the NAR of this path into `w` and flushes it, leaving out what
    /// the filter did not keep.
    pub fn nar(sp: SrcPath, gpa: Allocator, io: Io, w: *Io.Writer, d: *Diag) nar_mod.DumpError!void {
        switch (sp.src) {
            .mem => |contents| {
                try nar_mod.dumpString(contents, w);
                try w.flush();
            },
            .spool => |e| {
                var scratch: std.heap.ArenaAllocator = .init(gpa);
                defer scratch.deinit();
                // members are named as the filter recorded them: `/` plus
                // their path in the entry
                const shown = try spoolBase(scratch.allocator(), sp.rel);
                e.tree.dump(scratch.allocator(), sp.rel, shown, w, Filter{ .accepted = e.accepted }, d) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.WriteFailed => return error.WriteFailed,
                    else => if (d.msg == null) return d.fail(error.ReadFailed, "input-store:{s}: {t}", .{ e.name, err }) else return error.ReadFailed,
                };
            },
            .fs => |f| {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const full = if (sp.rel.len == 0) f.root else std.fmt.bufPrint(&buf, "{s}/{s}", .{ f.root, sp.rel }) catch
                    return d.fail(error.BadPath, "path '{s}/{s}' is too long", .{ f.root, sp.rel });
                const filter: Filter = .{ .accepted = f.accepted };
                try nar_mod.dumpPath(gpa, io, Io.Dir.cwd(), full, w, filter, d);
            },
        }
    }

    /// The name a spool dump gives the member `rel`, so its children are
    /// `/` plus their path in the entry: empty for the root.
    pub fn spoolBase(a: Allocator, rel: []const u8) Allocator.Error![]const u8 {
        return if (rel.len == 0) "" else std.mem.concat(a, u8, &.{ "/", rel });
    }

    const Filter = struct {
        accepted: ?*const PathSet,
        pub fn accept(f: Filter, p: []const u8, _: nar_mod.FileType) error{}!bool {
            const a = f.accepted orelse return true;
            return a.contains(p);
        }
    };

    /// Where the bytes are, for a message: the local root or the text itself,
    /// and `(filtered)` when a filter keeps part of the tree out of the copy.
    pub fn describe(sp: SrcPath, w: *Io.Writer) Io.Writer.Error!void {
        switch (sp.src) {
            .mem => return w.writeAll("text"),
            .spool => |e| {
                try w.print("input-store:{s}", .{e.name});
                if (sp.rel.len > 0) try w.print("/{s}", .{sp.rel});
                if (e.accepted != null) try w.writeAll(" (filtered)");
            },
            .fs => |f| {
                try w.writeAll(f.root);
                if (sp.rel.len > 0) try w.print("/{s}", .{sp.rel});
                if (f.accepted != null) try w.writeAll(" (filtered)");
            },
        }
    }
};

/// How an input source was content-addressed (store-api.hh:ContentAddress,
/// the three kinds eval produces).
pub const SourceKind = union(enum) {
    /// Recursive sha256 of the NAR, no references: `./path`, `fetchTarball`.
    source,
    /// Flat sha256 of one regular file plus references, sorted and unique:
    /// `builtins.toFile`.
    text: []const StorePath,
    /// Flat hash of one regular file, no references: `builtins.fetchurl`.
    flat: Hash,
};

pub const NarHash = nar_mod.NarHash;

/// Where an input source's bytes are and how it was addressed.
pub const SourceOrigin = struct {
    at: SrcPath,
    kind: SourceKind,
    /// The NAR hash and size the dump under the recorded filter produced, the
    /// exact pair `AddMultipleToStore` needs, so no upload path hashes the
    /// tree a second time. Null for a text, and for a store path the plan
    /// must hash itself.
    nar: ?NarHash = null,

    pub fn tree(at: SrcPath, nar_hash: Hash, nar_size: u64) SourceOrigin {
        return .{ .at = at, .kind = .source, .nar = .{ .hash = nar_hash, .size = nar_size } };
    }

    /// A flat fixed output named by `hash`, the hash of the one regular file
    /// at `at`, with the NAR hash and size of that file.
    pub fn flat(at: SrcPath, hash: Hash, nar_hash: Hash, nar_size: u64) SourceOrigin {
        return .{ .at = at, .kind = .{ .flat = hash }, .nar = .{ .hash = nar_hash, .size = nar_size } };
    }

    pub fn text(contents: []const u8, references: []const StorePath) SourceOrigin {
        return .{ .at = .mem(contents), .kind = .{ .text = references } };
    }

    /// The references of a `toFile` text.
    pub fn textRefs(o: SourceOrigin) ?[]const StorePath {
        return switch (o.kind) {
            .text => |r| r,
            .source, .flat => null,
        };
    }
};
