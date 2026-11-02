//! Flakes, as an operation: a reference is parsed, its lock is read, its
//! tree is resolved and its outputs are evaluated. The command
//! frontends call these, never `flake.zig`'s internals.

const std = @import("std");
const errors = @import("../errors.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Diag = @import("../diag.zig").Diag;
const Evaluator = @import("../eval/Evaluator.zig");
const Error = Evaluator.Error;
const Value = @import("../runtime/value.zig").Value;
const flake = @import("../flake.zig");
const source = @import("../source.zig");
const Attrs = source.Attrs;
const SourceRef = source.SourceRef;
const lock_mod = source.lock;

pub const FlakeRef = flake.FlakeRef;
pub const Tree = source.Tree;

/// A command-line input that names a flake rather than a `.nix` file.
pub const isFlakeRef = flake.isFlakeRef;

/// attr-path.cc:parseAttrPath: `.` separates, `"..."` quotes.
pub const parseAttrPath = flake.parseAttrPath;

/// eval-cache.cc:AttrCursor::findAlongAttrPath.
pub const select = flake.select;

/// flakeref.cc:FlakeRef::to_string for the references iets parses.
pub const url = flake.refUrl;

/// `PATH[#attr.path]` against `cwd`, `~` against `$HOME`.
pub fn flakeRef(a: Allocator, io: Io, f: []const u8, cwd: []const u8, d: *Diag) flake.RefError!FlakeRef {
    const h = std.c.getenv("HOME");
    const home: ?[]const u8 = if (h) |x| std.mem.span(x) else null;
    return flake.parseFlakeRef(a, io, f, cwd, home, d);
}

/// The flakes this run loaded, so installables of one flake load it once.
/// The source is part of the match: `path:.` and a git-tracked `.` are two
/// trees. Shared by the run's evaluators.
pub const Loaded = struct {
    lock: Io.Mutex = .init,
    items: std.ArrayList(struct { fr: FlakeRef, v: Value }) = .empty,

    pub fn deinit(l: *Loaded, gpa: Allocator) void {
        l.items.deinit(gpa);
    }

    fn get(l: *Loaded, io: Io, fr: *const FlakeRef) ?Value {
        l.lock.lockUncancelable(io);
        defer l.lock.unlock(io);
        for (l.items.items) |x| {
            if (std.mem.eql(u8, x.fr.dir, fr.dir) and x.fr.source.eql(&fr.source) and x.fr.probed == fr.probed and
                (x.fr.lock == null) == (fr.lock == null) and (fr.lock == null or std.mem.eql(u8, x.fr.lock.?, fr.lock.?))) return x.v;
        }
        return null;
    }

    fn put(l: *Loaded, gpa: Allocator, io: Io, fr: FlakeRef, v: Value) Allocator.Error!void {
        l.lock.lockUncancelable(io);
        defer l.lock.unlock(io);
        try l.items.append(gpa, .{ .fr = fr, .v = v });
    }
};

/// The value a flake installable names: its outputs with the reference's
/// attribute path selected, or with `whole` and no path the whole
/// `callFlake` result (`eval-jobs --flake DIR`). `reference_lock` is read in
/// place of the flake's `flake.lock`.
pub fn input(ev: *Evaluator, a: Allocator, f: []const u8, cwd: []const u8, reference_lock: ?[]const u8, whole: bool) Error!Value {
    var d: Diag = .init(a);
    var fr = flakeRef(a, ev.io, f, cwd, &d) catch |e| return flake.evalError(ev, e, &d, .none);
    if (reference_lock) |p| fr.lock = if (std.mem.startsWith(u8, p, "/")) p else try Evaluator.canonPath(a, try std.mem.concat(a, u8, &.{ cwd, "/", p }));
    const loaded = &ev.shared.flakes;
    const v = loaded.get(ev.io, &fr) orelse blk: {
        const w = try flake.evalFlakeValue(ev, &fr);
        try loaded.put(ev.gpa, ev.io, fr, w);
        break :blk w;
    };
    if (whole and fr.attr.len == 0) return v;
    return flake.selectOutput(ev, &fr, v);
}

/// The flake's outputs, with the reference's attribute path selected from
/// them. The lock is read, the inputs are fetched and `call-flake.nix` runs.
pub fn outputs(ev: *Evaluator, fr: *const FlakeRef) Error!Value {
    return flake.evalFlake(ev, fr);
}

/// The tree a reference names, copied or fetched if it is not here yet.
pub fn tree(ev: *Evaluator, r: *const SourceRef) Error!Tree {
    return source.tree(ev, r, .none);
}

/// What a flake names before anything is evaluated: the directory, where
/// its own tree comes from, and what its `flake.lock` locked.
pub const Info = struct {
    dir: []const u8,
    source: SourceRef,
    lock: lock_mod.Lock,

    /// Every locked input the lock reaches, with the name the lock gives
    /// it. A `path` input is left out: it is read in place, and a relative
    /// one is the root's own tree.
    pub fn inputs(i: *const Info, a: Allocator, d: *Diag) error{ Flake, OutOfMemory }![]const Input {
        var out: std.ArrayList(Input) = .empty;
        for (try i.lock.reachedInputs(a)) |r| {
            var attrs: Attrs = .{};
            var it = r.locked.iterator();
            while (it.next()) |kv| {
                const v: source.AttrVal = switch (kv.value_ptr.*) {
                    .string => |s| .{ .str = s },
                    .bool => |b| .{ .bool = b },
                    .integer => |n| if (n >= 0) .{ .int = @intCast(n) } else continue,
                    else => continue,
                };
                try attrs.put(a, kv.key_ptr.*, v);
            }
            const ty = source.strAttr(&attrs, "type");
            if (ty != null and std.mem.eql(u8, ty.?, "path")) continue;
            const locked_type = for ([_][]const u8{ "github", "gitlab", "sourcehut", "tarball", "git", "hg" }) |t| {
                if (ty != null and std.mem.eql(u8, ty.?, t)) break true;
            } else false;
            const h = source.strAttr(&attrs, "narHash");
            if (!locked_type or h == null) {
                if (ty) |t| return d.fail(error.Flake, "input '{s}' of type Some(\"{s}\")", .{ r.name, t });
                return d.fail(error.Flake, "input '{s}' of type None", .{r.name});
            }
            var hd: Diag = .init(a);
            const hash = source.parseNarHash(h.?, &hd) catch return d.fail(error.Flake, "input '{s}': {s}", .{ r.name, hd.message() });
            try attrs.put(a, "narHash", .{ .str = try hash.alloc(a, .sri, true) });
            try out.append(a, .{ .name = r.name, .source = .{ .locked = attrs } });
        }
        return out.items;
    }
};

pub const Input = struct { name: []const u8, source: SourceRef };

/// Reads `FLAKEREF/flake.lock` and checks it. Nothing is fetched and
/// nothing is evaluated.
pub fn info(a: Allocator, io: Io, fr: *const FlakeRef, d: *Diag) error{ Flake, OutOfMemory }!Info {
    const p = try source.scm.join(a, fr.dir, "flake.lock");
    const bytes = Io.Dir.cwd().readFileAlloc(io, p, a, .unlimited) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return d.fail(error.Flake, "flake.lock: {f}", .{errors.os(e)}),
    };
    var ld: Diag = .init(a);
    const lock = lock_mod.check(a, bytes, &ld) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Flake => return d.fail(error.Flake, "flake.lock: {s}", .{ld.message()}),
    };
    return .{ .dir = fr.dir, .source = fr.source, .lock = lock };
}
