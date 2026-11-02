//! What a command line or a nix.conf asked for and iets does not do. Each
//! is one level-1 warning per key and process that
//! says why, never silence (docs/reference/errors.md: `ignored-flag`,
//! `ignored-setting`, `unknown-setting`). A warning waits for `flush`, so a
//! later `--log-format` still applies to it, as Nix warns only once every
//! flag is read (common-args.cc:initialFlagsProcessed).
//!
//! `accept-flake-config` waits longer: Nix does nothing with it until a
//! top-level flake has a `nixConfig`, so neither does iets's warning
//! (`nixConfigSeen`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Log = @import("log.zig").Log;

const Note = struct {
    code: []const u8,
    key: []u8,
    raw: []u8,
    warned: bool = false,
    for_nix_config: bool,
};

/// Why `-v`, `--verbose` and `--debug` change nothing.
pub const one_log_level = "iets has one log level, the one Nix starts at";

/// Why `--accept-flake-config` and the `accept-flake-config` setting change
/// nothing (docs/reference/divergences.md).
pub const no_nix_config = "iets never applies a flake's nixConfig, so a flake that sets extra-substituters or allow-import-from-derivation there runs without them; put the settings in nix.conf";

/// The notes of one run, `hushed`, and whether a top-level flake had a
/// `nixConfig`. The session owns it.
pub const Ignored = struct {
    gpa: Allocator,
    io: std.Io,
    /// Where `flush` warns; null says nothing (a test reads `noted`).
    log: ?*Log = null,
    hushed: std.atomic.Value(bool) = .init(false),
    nix_config: std.atomic.Value(bool) = .init(false),
    lock: std.Io.Mutex = .init,
    notes: std.ArrayList(Note) = .empty,

    pub fn init(gpa: Allocator, io: std.Io) Ignored {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(ig: *Ignored) void {
        for (ig.notes.items) |n| {
            ig.gpa.free(n.key);
            ig.gpa.free(n.raw);
        }
        ig.notes.deinit(ig.gpa);
    }

    /// No warnings from this run: an `eval-jobs` worker, whose parent
    /// already gave them.
    pub fn hush(ig: *Ignored) void {
        ig.hushed.store(true, .monotonic);
    }

    fn push(ig: *Ignored, code: []const u8, key: []const u8, raw: []const u8, for_nix_config: bool) !void {
        ig.lock.lockUncancelable(ig.io);
        defer ig.lock.unlock(ig.io);
        for (ig.notes.items) |n| if (std.mem.eql(u8, n.code, code) and std.mem.eql(u8, n.key, key)) return;
        const k = try ig.gpa.dupe(u8, key);
        errdefer ig.gpa.free(k);
        const r = try ig.gpa.dupe(u8, raw);
        errdefer ig.gpa.free(r);
        try ig.notes.append(ig.gpa, .{ .code = code, .key = k, .raw = r, .for_nix_config = for_nix_config });
    }

    /// Remembers the warning `raw`, once per `code` and `key`.
    pub fn note(ig: *Ignored, code: []const u8, key: []const u8, raw: []const u8) !void {
        return ig.push(code, key, raw, false);
    }

    /// `note` for `accept-flake-config`: `flush` gives it only once
    /// `nixConfigSeen` said a top-level flake has a `nixConfig`.
    pub fn noteForNixConfig(ig: *Ignored, code: []const u8, key: []const u8, raw: []const u8) !void {
        return ig.push(code, key, raw, true);
    }

    /// `warning: 'FLAG' is ignored: WHY`, an `ignored-flag` record.
    pub fn flag(ig: *Ignored, f: []const u8, why: []const u8) !void {
        const raw = try std.fmt.allocPrint(ig.gpa, "'{s}' is ignored: {s}", .{ f, why });
        defer ig.gpa.free(raw);
        return ig.note("ignored-flag", f, raw);
    }

    /// `flag` for `--accept-flake-config`, which waits like `noteForNixConfig`.
    pub fn flagForNixConfig(ig: *Ignored, f: []const u8) !void {
        const raw = try std.fmt.allocPrint(ig.gpa, "'{s}' is ignored: " ++ no_nix_config, .{f});
        defer ig.gpa.free(raw);
        return ig.noteForNixConfig("ignored-flag", f, raw);
    }

    /// A top-level flake of this run has a `nixConfig`: the notes that
    /// waited for one are given now.
    pub fn nixConfigSeen(ig: *Ignored) void {
        ig.nix_config.store(true, .monotonic);
        ig.flush();
    }

    pub fn nixConfigWasSeen(ig: *const Ignored) bool {
        return ig.nix_config.load(.monotonic);
    }

    /// Every note not yet given, in the order they were made.
    pub fn flush(ig: *Ignored) void {
        const hushed = ig.hushed.load(.monotonic);
        const nix_config = ig.nix_config.load(.monotonic);
        ig.lock.lockUncancelable(ig.io);
        defer ig.lock.unlock(ig.io);
        for (ig.notes.items) |*n| {
            if (n.warned or (!nix_config and n.for_nix_config)) continue;
            n.warned = true;
            if (!hushed) if (ig.log) |l| l.warning(n.code, n.raw);
        }
    }

    /// Whether `key` was noted under `code`, for the tests.
    pub fn noted(ig: *Ignored, code: []const u8, key: []const u8) bool {
        ig.lock.lockUncancelable(ig.io);
        defer ig.lock.unlock(ig.io);
        for (ig.notes.items) |n| if (std.mem.eql(u8, n.code, code) and std.mem.eql(u8, n.key, key)) return true;
        return false;
    }
};

const testing = std.testing;

test "a note is given once, and a nixConfig note waits" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    var l: Log = .init(testing.allocator, testing.io, .{});
    defer l.deinit();
    l.writeTo(&buf.writer);
    l.stderr_tty = false;
    l.sink_state = .none;
    var ig: Ignored = .init(testing.allocator, testing.io);
    defer ig.deinit();
    ig.log = &l;
    try ig.flag("--verbose", one_log_level);
    try ig.flag("--verbose", one_log_level);
    try ig.flagForNixConfig("--accept-flake-config");
    ig.flush();
    ig.flush();
    try testing.expectEqualStrings("warning: '--verbose' is ignored: " ++ one_log_level ++ "\n", buf.written());
    ig.nixConfigSeen();
    try testing.expect(std.mem.endsWith(u8, buf.written(), "warning: '--accept-flake-config' is ignored: " ++ no_nix_config ++ "\n"));
    try testing.expect(ig.nixConfigWasSeen());
    ig.hush();
    try ig.note("x", "y", "z");
    const before = buf.written().len;
    ig.flush();
    try testing.expectEqual(before, buf.written().len);
}
