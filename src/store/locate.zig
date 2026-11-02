//! Where the local store keeps an input source. Querying a store path's
//! references, and prefetching them, live with the evaluator's store hooks
//! (builtins/store_hooks.zig).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Diag = @import("../diag.zig").Diag;
const Env = @import("../env.zig").Env;
const nixbin = @import("../nixbin.zig");
const StorePath = @import("path.zig").StorePath;
const source = @import("source.zig");
const SourceOrigin = source.SourceOrigin;
const SrcPath = source.SrcPath;

pub const Error = error{ Io, Protocol, Store, OutOfMemory };

/// `--source STOREPATH=LOCAL`: full store path to a local tree.
pub const Overrides = std.StringArrayHashMapUnmanaged([]const u8);

/// Which `nix` to run and in what environment.
pub const Nix = struct {
    io: Io,
    env: Env,
    nix_bin_dir: ?[]const u8 = null,
};

/// Answers the plan's locator from the local Nix store: one `nix path-info
/// --json` call tells how each input source was content-addressed and what
/// it references. Paths named by `--source` are read from the given local
/// tree instead and are plain sources. A path that is not valid locally, or
/// whose content address v1 cannot send (an input-addressed output pinned
/// with `builtins.storePath`), is null: the daemon substitutes it. `out`
/// has one slot per path; everything is allocated in `arena`.
pub fn locateInStore(arena: Allocator, nix: Nix, paths: []const StorePath, overrides: *const Overrides, out: []?SourceOrigin, d: *Diag) Error!void {
    var ask: std.ArrayList([]const u8) = .empty;
    const full = try arena.alloc([]const u8, paths.len);
    for (paths, full) |*p, *f| {
        f.* = try std.fmt.allocPrint(arena, "{f}", .{p});
        if (!overrides.contains(f.*)) try ask.append(arena, f.*);
    }
    var info: ?std.json.Value = null;
    if (ask.items.len > 0) {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ nixbin.nix(arena, nix.io, nix.env, nix.nix_bin_dir), "--extra-experimental-features", "nix-command", "path-info", "--json" });
        try argv.appendSlice(arena, ask.items);
        var child = std.process.spawn(nix.io, .{ .argv = argv.items, .stdin = .ignore, .stdout = .pipe, .stderr = .inherit }) catch |e|
            return d.fail(error.Io, "nix path-info: {t}", .{e});
        var rbuf: [4096]u8 = undefined;
        var r = child.stdout.?.readerStreaming(nix.io, &rbuf);
        const stdout = r.interface.allocRemaining(arena, .unlimited) catch |e| {
            child.kill(nix.io);
            return d.fail(error.Io, "nix path-info: {t}", .{e});
        };
        const term = child.wait(nix.io) catch |e| return d.fail(error.Io, "nix path-info: {t}", .{e});
        const ok = switch (term) {
            .exited => |c| c == 0,
            else => false,
        };
        if (!ok) return d.fail(error.Protocol, "nix path-info failed", .{});
        info = std.json.parseFromSliceLeaky(std.json.Value, arena, stdout, .{}) catch |e|
            return d.fail(error.Protocol, "nix path-info: {t}", .{e});
    }
    for (paths, full, out) |*p, f, *slot| {
        slot.* = null;
        if (overrides.get(f)) |local| {
            slot.* = .{ .at = .fs(local, null), .kind = .source };
            continue;
        }
        const all = info orelse continue;
        if (all != .object) continue;
        // `null` is what `nix path-info` prints for a path that is not valid.
        const v = all.object.get(f) orelse continue;
        if (v != .object) continue;
        const ca = if (v.object.get("ca")) |c| (if (c == .string) c.string else "") else "";
        const at: SrcPath = .fs(try std.fmt.allocPrint(arena, "{s}/{s}", .{ @import("path.zig").store_dir, p.baseName() }), null);
        if (std.mem.startsWith(u8, ca, "fixed:r:sha256:")) {
            slot.* = .{ .at = at, .kind = .source };
        } else if (std.mem.startsWith(u8, ca, "text:sha256:")) {
            var refs: std.ArrayList(StorePath) = .empty;
            if (v.object.get("references")) |rs| if (rs == .array) for (rs.array.items) |r| {
                if (r != .string) continue;
                try refs.append(arena, StorePath.parse(r.string, d) catch return error.Store);
            };
            slot.* = .{ .at = at, .kind = .{ .text = refs.items } };
        }
    }
}

test "an override is a plain source and asks no store" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var d: Diag = .init(std.testing.allocator);
    defer d.deinit();
    const p: StorePath = try .parse("/nix/store/00000000000000000000000000000000-src", &d);
    var o: Overrides = .empty;
    try o.put(arena.allocator(), "/nix/store/00000000000000000000000000000000-src", "/home/u/src");
    var out: [1]?SourceOrigin = undefined;
    try locateInStore(arena.allocator(), .{ .io = std.testing.io, .env = .{} }, &.{p}, &o, &out, &d);
    try std.testing.expectEqualStrings("/home/u/src", out[0].?.at.src.fs.root);
    try std.testing.expect(out[0].?.kind == .source);
}
