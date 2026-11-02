//! Compiled-IR cache on disk. The first compile of a file writes its IR;
//! later runs load it and neither parse nor compile the file again
//! (docs/explanation/caching.md, "The IR cache").
//!
//! The IR depends on the process in three ways, and an entry undoes each:
//!
//! - `Sym` ids: the entry has its own name table, which the load interns.
//! - `Pos` values: stored relative to the file, rebased on load.
//! - Constant values: literals are stored by content; globals and
//!   `builtins.x` by name, looked up in the live tables on load.
//!
//! Binding frames (`let`, `rec`, formals) and sets are in `Sym` id order, so
//! the loader sorts them again and rewrites every `local` index through a
//! permutation stack that mirrors the compiler's scopes. Tags are the IR's
//! own enum values: the key holds the build id, so a change to the IR never
//! meets an entry of another layout.

const std = @import("std");
const Scratch = @import("Scratch.zig");
const ast = @import("syntax/ast.zig");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ir = @import("eval/ir.zig");
const Ir = ir.Ir;
const Evaluator = @import("eval/Evaluator.zig");
const value = @import("runtime/value.zig");
const Value = value.Value;
const Sym = @import("syntax/symbol.zig").Sym;
const Pos = @import("syntax/pos.zig").Pos;
const cachefs = @import("cachefs.zig");
const build_id = @import("build_options").build_id;
const lint = @import("lint.zig");
const Allows = lint.allow.Allows;

const magic = "IETSZIR1";

pub const IrCache = struct {
    io: Io,
    gpa: Allocator,
    /// The store directory, `<cache root>/ir`.
    dir: Io.Dir,
    /// Sources below this size compile faster than their entry loads.
    min_size: usize = 1024,
    /// `IETS_IR_STATS=1`: one line per file on stderr.
    stats: ?*Io.Writer = null,
    /// The store is swept at most once per process, on the first write.
    swept: std.atomic.Value(bool) = .init(false),
    /// Entries read, over every fiber.
    hits: std.atomic.Value(u64) = .init(0),

    /// The store under `root`, or null when it is not iets's to write in.
    pub fn open(gpa: Allocator, io: Io, root: []const u8, stderr: ?*Io.Writer) !?IrCache {
        const path = try std.fs.path.join(gpa, &.{ root, "ir" });
        defer gpa.free(path);
        if (!cachefs.prepare(io, path, stderr)) return null;
        const dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return null;
        return .{ .io = io, .gpa = gpa, .dir = dir };
    }

    pub fn close(c: *IrCache) void {
        c.dir.close(c.io);
    }

    /// Everything the compiler folds out of the evaluator's configuration:
    /// `system`, the store directory and `pure`, which removes the
    /// impure-only names. Every other constant is looked up by name on load,
    /// and a `~/` literal is never cached. `lint_key` is
    /// `lint.Config.compileKey`, whose warnings the entry carries.
    pub fn key(path: []const u8, src: []const u8, system: []const u8, store_dir: []const u8, lint_key: []const u8, pure: bool) [64]u8 {
        // The source is hashed on its own from offset 0, chunk-aligned, so
        // its chunks go through Blake3's wide path; after the short fields
        // they went through the one-chunk path, at a third of the speed.
        var sd: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(src, &sd, .{});
        var h: std.crypto.hash.Blake3 = .init(.{});
        for ([_][]const u8{ build_id, path, system, store_dir, lint_key, &.{@intFromBool(pure)} }) |part| {
            h.update(part);
            h.update("\x00");
        }
        h.update(&sd);
        var d: [32]u8 = undefined;
        h.final(&d);
        return std.fmt.bytesToHex(d, .lower);
    }

    /// The entry, owned by the caller (`body` is its IR); null on a miss.
    /// An entry whose sum is wrong is removed.
    pub fn read(c: *IrCache, k: *const [64]u8) ?[]u8 {
        var shard = c.dir.openDir(c.io, k[0..2], .{}) catch return null;
        defer shard.close(c.io);
        const bytes = cachefs.readEntry(c.io, shard, k[2..], c.gpa) orelse return null;
        if (bytes.len < cachefs.sum_len or !std.mem.eql(u8, bytes[bytes.len - cachefs.sum_len ..], &cachefs.checksum(k, &.{bytes[0 .. bytes.len - cachefs.sum_len]}))) {
            c.gpa.free(bytes);
            shard.deleteFile(c.io, k[2..]) catch {};
            return null;
        }
        _ = c.hits.fetchAdd(1, .monotonic);
        return bytes;
    }

    /// An entry read without its integrity sum.
    pub fn body(entry: []const u8) []const u8 {
        return entry[0 .. entry.len - cachefs.sum_len];
    }

    /// Skips the write when a sibling process holds the store lock: the file
    /// compiles again next run, which is cheaper than waiting here.
    pub fn write(c: *IrCache, k: *const [64]u8, bytes: []const u8) void {
        c.dir.createDirPath(c.io, k[0..2]) catch return;
        var shard = c.dir.openDir(c.io, k[0..2], .{}) catch return;
        defer shard.close(c.io);
        if (cachefs.writeLock(c.io, c.dir)) |l| {
            defer cachefs.unlock(c.io, l);
            const sum = cachefs.checksum(k, &.{bytes});
            cachefs.writeAtomic(c.io, shard, k[2..], &.{ bytes, &sum }) catch {};
            if (!c.swept.swap(true, .monotonic)) cachefs.maybeSweep(c.io, c.dir);
        }
    }

    /// Poison and wipe, never repair: an entry that does not decode goes.
    pub fn discard(c: *IrCache, k: *const [64]u8) void {
        var shard = c.dir.openDir(c.io, k[0..2], .{}) catch return;
        defer shard.close(c.io);
        shard.deleteFile(c.io, k[2..]) catch {};
    }
};

fn putU64(out: *std.ArrayList(u8), gpa: Allocator, v_: u64) !void {
    var v = v_;
    while (v >= 0x80) : (v >>= 7) try out.append(gpa, @as(u8, @truncate(v)) | 0x80);
    try out.append(gpa, @truncate(v));
}

const Ser = struct {
    gpa: Allocator,
    out: std.ArrayList(u8) = .empty,
    syms: std.AutoHashMapUnmanaged(Sym, u32) = .empty,
    names: std.ArrayList(Sym) = .empty,
    base: u32,
    /// A global's or builtin's value word: whether it is a global, its name.
    rev: std.AutoHashMapUnmanaged(u64, struct { bool, Sym }) = .empty,
    ok: bool = true,

    fn deinit(s: *Ser) void {
        s.out.deinit(s.gpa);
        s.syms.deinit(s.gpa);
        s.names.deinit(s.gpa);
        s.rev.deinit(s.gpa);
    }

    fn byte(s: *Ser, b: u8) !void {
        try s.out.append(s.gpa, b);
    }

    fn int(s: *Ser, v: u64) !void {
        try putU64(&s.out, s.gpa, v);
    }

    fn bytes(s: *Ser, b: []const u8) !void {
        try s.int(b.len);
        try s.out.appendSlice(s.gpa, b);
    }

    fn sym(s: *Ser, x: Sym) !void {
        const gop = try s.syms.getOrPut(s.gpa, x);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(s.names.items.len);
            try s.names.append(s.gpa, x);
        }
        try s.int(gop.value_ptr.*);
    }

    fn pos(s: *Ser, p: Pos) !void {
        try s.int(if (p == .none) std.math.maxInt(u32) else @backingInt(p) - s.base);
    }

    fn optNode(s: *Ser, n: ?ir.Ref) !void {
        try s.byte(@intFromBool(n != null));
        if (n) |x| try s.node(x);
    }

    fn optSym(s: *Ser, x: ?Sym) !void {
        try s.byte(@intFromBool(x != null));
        if (x) |y| try s.sym(y);
    }

    fn nodes(s: *Ser, ns: []const ir.Ref) !void {
        try s.int(ns.len);
        for (ns) |n| try s.node(n);
    }

    fn elems(s: *Ser, path: []const ir.AttrElem) !void {
        try s.int(path.len);
        for (path) |e| switch (e) {
            .static => |x| {
                try s.byte(0);
                try s.sym(x);
            },
            .dynamic => |d| {
                try s.byte(1);
                try s.node(d);
            },
        };
    }

    fn word(s: *Ser, v: Value) !void {
        switch (v.tag()) {
            .int, .imm => {
                try s.byte(@backingInt(ConstTag.imm));
                return s.int(v.bits());
            },
            .ptr => switch (v.obj().kind) {
                .string => {
                    const str = v.as(value.String);
                    if (str.ctx_len != 0) {
                        s.ok = false;
                        return;
                    }
                    try s.byte(@backingInt(ConstTag.str));
                    return s.bytes(str.bytes());
                },
                .path => {
                    try s.byte(@backingInt(ConstTag.path));
                    return s.bytes(v.as(value.Path).bytes());
                },
                .float => {
                    try s.byte(@backingInt(ConstTag.float));
                    return s.out.appendSlice(s.gpa, std.mem.asBytes(&std.mem.nativeToLittle(u64, @bitCast(v.as(value.FloatObj).val))));
                },
                .int => {
                    try s.byte(@backingInt(ConstTag.int));
                    return s.out.appendSlice(s.gpa, std.mem.asBytes(&std.mem.nativeToLittle(i64, v.as(value.IntObj).val)));
                },
                // the compiler's `[ ]` and `{ }`
                .list => if (v.as(value.List).len == 0) return s.byte(@backingInt(ConstTag.empty_list)),
                .attrs => if (v.as(value.Attrs).len == 0) return s.byte(@backingInt(ConstTag.empty_attrs)),
                else => {},
            },
            else => {},
        }
        const named = s.rev.get(v.bits()) orelse {
            s.ok = false;
            return;
        };
        try s.byte(@backingInt(if (named[0]) ConstTag.global else ConstTag.builtin));
        try s.sym(named[1]);
    }

    /// A binding frame: the headers, the `from` count, then the values and
    /// the `from` expressions. The loader needs both counts before it reads
    /// a value, so it can size the slot permutation.
    fn binds(s: *Ser, bs: []const ir.Bind, from: []const ir.Ref) !void {
        try s.int(bs.len);
        for (bs) |b| {
            try s.sym(b.sym);
            try s.pos(b.pos);
            try s.byte(@backingInt(b.scope));
        }
        try s.int(from.len);
        // A huge run of values carries where its slices start, so a load
        // can read them on several workers (`De.bindsParallel`).
        if (bs.len >= slices_min) {
            const k = sliceCount(bs.len);
            try s.int(k);
            const table = s.out.items.len;
            try s.out.appendNTimes(s.gpa, 0, 4 * k);
            const start = s.out.items.len;
            for (0..k) |j| {
                std.mem.writeInt(u32, s.out.items[table + 4 * j ..][0..4], @intCast(s.out.items.len - start), .little);
                for (bs[bs.len * j / k .. bs.len * (j + 1) / k]) |b| try s.node(b.value);
            }
        } else for (bs) |b| try s.node(b.value);
        for (from) |f| try s.node(f);
    }

    fn node(s: *Ser, n: ir.Ref) Allocator.Error!void {
        if (!s.ok) return;
        try s.byte(@backingInt(n.*));
        switch (n.*) {
            .constant => |v| try s.word(v),
            .local => |l| {
                try s.int(l.depth);
                try s.int(l.idx);
            },
            .with_var => |w| {
                try s.sym(w.sym);
                try s.int(w.withs.len);
                for (w.withs) |d| try s.int(d);
                try s.pos(w.pos);
            },
            .cur_pos => |p| try s.pos(p),
            .concat => |c| {
                try s.byte(@intFromBool(c.force_string));
                try s.nodes(c.parts);
                try s.pos(c.pos);
            },
            .search_path => |sp| {
                try s.node(sp.name);
                try s.pos(sp.pos);
            },
            .select => |sel| {
                try s.node(sel.subject);
                try s.elems(sel.path);
                try s.optNode(sel.default);
                try s.pos(sel.pos);
            },
            .select_count => |sel| {
                try s.node(sel.subject);
                try s.elems(sel.path);
                try s.optNode(sel.default);
                try s.pos(sel.pos);
            },
            .select1 => |sel| {
                try s.node(sel.subject);
                try s.sym(sel.sym);
                try s.optNode(sel.default);
                try s.pos(sel.pos);
            },
            .has_attr => |h| {
                try s.node(h.subject);
                try s.elems(h.path);
            },
            .attrs => |a| {
                try s.byte(@intFromBool(a.rec));
                try s.pos(a.pos);
                try s.binds(a.binds, a.from);
                try s.int(a.dynamic.len);
                for (a.dynamic) |d| {
                    try s.node(d.name);
                    try s.node(d.value);
                    try s.pos(d.pos);
                }
            },
            .list => |items| try s.nodes(items),
            .lambda => |l| {
                switch (l.param) {
                    .ident => try s.byte(if (l.no_env) @backingInt(ParamTag.ident_no_env) else @backingInt(ParamTag.ident)),
                    .formals => |f| {
                        try s.byte(@backingInt(ParamTag.formals));
                        try s.byte(@intFromBool(f.has_bind));
                        try s.byte(@intFromBool(f.ellipsis));
                        try s.int(f.formals.len);
                        for (f.formals) |x| {
                            try s.sym(x.sym);
                            try s.pos(x.pos);
                        }
                        for (f.formals) |x| try s.optNode(x.default);
                    },
                }
                try s.node(l.body);
                try s.pos(l.pos);
                try s.optSym(l.name);
                try s.optSym(l.arg);
            },
            .apply => |*a| {
                try s.node(a.func);
                try s.nodes(a.args());
                try s.pos(a.pos);
            },
            .let => |l| {
                try s.binds(l.binds, l.from);
                try s.node(l.body);
            },
            .with => |w| {
                try s.node(w.scope);
                try s.node(w.body);
                try s.pos(w.pos);
            },
            .@"if" => |i| {
                try s.node(i.cond);
                try s.node(i.branches[0]);
                try s.node(i.branches[1]);
                try s.pos(i.pos);
            },
            .assert => |a| {
                try s.node(a.cond);
                try s.node(a.body);
                try s.pos(a.pos);
            },
            .not => |x| {
                try s.node(x.e);
                try s.pos(x.pos);
            },
            .neg => |x| {
                try s.node(x.e);
                try s.pos(x.pos);
            },
            .binop => |b| {
                try s.byte(@backingInt(b.op));
                try s.node(b.a);
                try s.node(b.b);
                try s.pos(b.pos);
            },
            // only the import machinery makes these, never the compiler
            .import_file => s.ok = false,
        }
    }
};

const ConstTag = enum(u8) { imm, str, path, float, int, global, builtin, empty_list, empty_attrs };
const ParamTag = enum(u8) { ident, formals, ident_no_env };

/// The entry for `code`, compiled from the file at `base`, with the lint
/// warnings its compile produced and the file's allow table, owned by the
/// caller; null when a constant cannot be named.
pub fn serialize(ev: *Evaluator, code: ir.Ref, base: u32, diags: []const lint.Diag, allows: *const Allows) Allocator.Error!?[]u8 {
    var s: Ser = .{ .gpa = ev.gpa, .base = base };
    defer s.deinit();
    if (ev.globals.get(try ev.interner.intern("builtins"))) |b| if (b.kind() == .attrs) for (b.as(value.Attrs).attrs()) |a| {
        try s.rev.put(ev.gpa, a.cell.get().bits(), .{ false, a.sym });
    };
    var it = ev.globals.iterator();
    while (it.next()) |e| try s.rev.put(ev.gpa, e.value_ptr.bits(), .{ true, e.key_ptr.* });
    try s.node(code);
    if (!s.ok) return null;
    var file: std.ArrayList(u8) = .empty;
    errdefer file.deinit(ev.gpa);
    try file.appendSlice(ev.gpa, magic);
    try putU64(&file, ev.gpa, s.names.items.len);
    for (s.names.items) |x| {
        const name = ev.interner.name(x);
        try putU64(&file, ev.gpa, name.len);
        try file.appendSlice(ev.gpa, name);
    }
    try putU64(&file, ev.gpa, diags.len);
    for (diags) |dg| {
        try file.append(ev.gpa, @backingInt(dg.id));
        try putU64(&file, ev.gpa, if (dg.pos == .none) std.math.maxInt(u32) else @backingInt(dg.pos) - base);
        try putU64(&file, ev.gpa, dg.msg.len);
        try file.appendSlice(ev.gpa, dg.msg);
    }
    try putU64(&file, ev.gpa, allows.lines.items.len);
    for (allows.lines.items) |l| {
        try putU64(&file, ev.gpa, l.start);
        try putU64(&file, ev.gpa, l.end);
        try putU64(&file, ev.gpa, l.mask);
    }
    try file.appendSlice(ev.gpa, s.out.items);
    return try file.toOwnedSlice(ev.gpa);
}

/// One scope the compiler pushed. The loader mirrors the compiler's scope
/// stack so it can check every stored index against the env that will hold
/// it: a `local` past the end of its frame would read past an env.
const Frame = struct {
    /// Slots the env at this depth has.
    slots: u32,
    /// A `with` scope: only these carry a `with_var` depth.
    with: bool = false,
    /// The slot permutation of a re-sorted frame, null for an unchanged one.
    perm: ?std.ArrayList(u32) = null,

    /// Append `n` slots, permuted by `p` (relative to the first of them)
    /// when given; the old size is the new slots' base.
    fn extend(f: *Frame, a: Allocator, n: u32, p: ?[]const u32) !u32 {
        const base = f.slots;
        if (p != null or f.perm != null) {
            if (f.perm == null) {
                f.perm = .empty;
                for (0..base) |i| try f.perm.?.append(a, @intCast(i));
            }
            if (p) |q| {
                for (q) |i| try f.perm.?.append(a, i + base);
            } else for (base..base + n) |i| try f.perm.?.append(a, @intCast(i));
        }
        f.slots += n;
        return base;
    }

    fn truncate(f: *Frame, base: u32) void {
        f.slots = base;
        if (f.perm) |*p| p.shrinkRetainingCapacity(base);
    }
};

/// Open `node` calls. Real IR nests far below this; a crafted entry that
/// nests deeper would exhaust the stack.
const max_nest = 10_000;

var null_node: Ir = .{ .constant = .null };

/// Binding runs this long carry a table of where their slices start.
const slices_min = 2048;

fn sliceCount(n: usize) u32 {
    return @intCast(@min(Evaluator.Jobs.max, n / 256));
}

const Slices = struct {
    k: u32,
    /// `k` little-endian offsets of each slice from `start`.
    table: []const u8,
    start: usize,

    fn at(sl: Slices, j: usize) usize {
        return sl.start + std.mem.readInt(u32, sl.table[4 * j ..][0..4], .little);
    }
};

const SliceJob = struct {
    d: *const De,
    sl: Slices,
    syms: []const Sym,
    poss: []const Pos,
    scopes: []const ir.BindScope,
    nfrom: u32,
    p: ?[]const u32,
    out: []ir.Bind,
    bad: std.atomic.Value(bool) = .init(false),
    oom: std.atomic.Value(bool) = .init(false),
    /// Where the last slice ended, written by its reader.
    end: usize = 0,

    fn run(ctx: *anyopaque, j: u32, ev: *Evaluator) void {
        const job: *SliceJob = @ptrCast(@alignCast(ctx));
        job.slice(j, ev) catch job.oom.store(true, .release);
    }

    fn slice(job: *SliceJob, j: u32, ev: *Evaluator) Allocator.Error!void {
        const n = job.syms.len;
        const k = job.sl.k;
        var scratch: Scratch = .init(ev.gpa);
        defer scratch.deinit();
        var d = job.d.*;
        d.ev = ev;
        d.a = scratch.allocator();
        d.frames = .empty;
        try d.frames.appendSlice(d.a, job.d.frames.items);
        d.body_of = null;
        d.at = job.sl.at(j);
        if (d.at > d.data.len) return job.bad.store(true, .release);
        for (n * j / k..n * (j + 1) / k) |i| {
            const v = try d.bindValue(job.scopes[i], false, false, 0, 0, job.nfrom, job.p);
            const new = if (job.p) |q| q[i] else i;
            job.out[new] = .{ .sym = job.syms[i], .pos = job.poss[i], .scope = job.scopes[i], .value = if (d.ok) v else &null_node };
        }
        if (!d.ok) return job.bad.store(true, .release);
        if (j + 1 < k) {
            if (d.at != job.sl.at(j + 1)) job.bad.store(true, .release);
        } else job.end = d.at;
    }
};

const De = struct {
    ev: *Evaluator,
    /// Temporaries of the load: frames, permutations, symbol lists.
    a: Allocator,
    data: []const u8,
    at: usize,
    syms: []Sym = &.{},
    base: u32,
    /// Byte length of the source: every stored position is inside it.
    span: u32,
    /// Items the counted runs may still ask for; each costs at least a
    /// byte, so a crafted count cannot make the arena grow without bound.
    budget: usize,
    frames: std.ArrayList(Frame) = .empty,
    /// Slots of the innermost frame when the next node is the body of the
    /// lambda that frame belongs to: a lambda or `let` there extends it.
    body_of: ?u32 = null,
    nest: u32 = 0,
    ok: bool = true,

    fn u8_(d: *De) u8 {
        if (d.at >= d.data.len) {
            d.ok = false;
            return 0;
        }
        d.at += 1;
        return d.data[d.at - 1];
    }

    fn u64_(d: *De) u64 {
        var v: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            const b = d.u8_();
            v |= @as(u64, b & 0x7f) << shift;
            if (b < 0x80 or !d.ok or shift >= 63 - 7) return v;
            shift += 7;
        }
    }

    fn u32_(d: *De) u32 {
        return @truncate(d.u64_());
    }

    fn flag(d: *De) bool {
        return d.u8_() != 0;
    }

    fn bytes(d: *De) []const u8 {
        const n = d.u32_();
        if (n > d.data.len - d.at) {
            d.ok = false;
            return &.{};
        }
        defer d.at += n;
        return d.data[d.at..][0..n];
    }

    fn sym(d: *De) Sym {
        const i = d.u32_();
        if (i >= d.syms.len) {
            d.ok = false;
            return @fromBackingInt(0);
        }
        return d.syms[i];
    }

    fn pos(d: *De) Pos {
        const v = d.u32_();
        if (v == std.math.maxInt(u32)) return .none;
        if (v > d.span) {
            d.ok = false;
            return .none;
        }
        return @fromBackingInt(d.base + v);
    }

    fn optSym(d: *De) ?Sym {
        return if (d.flag()) d.sym() else null;
    }

    fn optNode(d: *De) Allocator.Error!?ir.Ref {
        return if (d.flag()) try d.node() else null;
    }

    /// A count of items to follow, against the entry's item budget.
    fn count(d: *De) u32 {
        const n = d.u32_();
        if (n > d.budget or n > d.data.len - @min(d.at, d.data.len)) {
            d.ok = false;
            return 0;
        }
        d.budget -= n;
        return n;
    }

    fn alloc(d: *De, comptime T: type, n: usize) Allocator.Error![]T {
        return d.ev.local.arena.allocSlice(T, n);
    }

    fn create(d: *De, v: Ir) Allocator.Error!ir.Ref {
        return d.ev.irNode(v) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => unreachable,
        };
    }

    fn nodes(d: *De) Allocator.Error![]const ir.Ref {
        const out = try d.alloc(ir.Ref, d.count());
        for (out) |*o| o.* = try d.node();
        return out;
    }

    fn elems(d: *De) Allocator.Error![]const ir.AttrElem {
        const out = try d.alloc(ir.AttrElem, d.count());
        for (out) |*o| o.* = switch (d.u8_()) {
            0 => .{ .static = d.sym() },
            1 => .{ .dynamic = try d.node() },
            else => blk: {
                d.ok = false;
                break :blk .{ .static = @fromBackingInt(0) };
            },
        };
        return out;
    }

    fn word(d: *De) Evaluator.Error!Value {
        const ev = d.ev;
        const t = std.enums.fromInt(ConstTag, d.u8_()) orelse {
            d.ok = false;
            return .null;
        };
        switch (t) {
            .imm => {
                const v: Value = @fromBackingInt(d.u64_());
                // only an immediate int, `null`, `true` or `false`
                if (v.tag() == .int or v == .null or v == .true or v == .false) return v;
                d.ok = false;
                return .null;
            },
            .str => return ev.mkString(d.bytes()),
            .path => return ev.mkPath(d.bytes()),
            .float, .int => {
                if (d.data.len - d.at < 8) {
                    d.ok = false;
                    return .null;
                }
                const raw = std.mem.readInt(u64, d.data[d.at..][0..8], .little);
                d.at += 8;
                return if (t == .float) ev.mkFloat(@bitCast(raw)) else ev.mkInt(@bitCast(raw));
            },
            .empty_list => return ev.mkList(&.{}),
            .empty_attrs => return ev.emptyAttrs(),
            .global => {
                if (ev.globals.get(d.sym())) |v| return v;
            },
            .builtin => {
                const s = d.sym();
                if (ev.globals.get(try ev.interner.intern("builtins"))) |b| if (b.kind() == .attrs) if (b.as(value.Attrs).get(s)) |a| return a.cell.get();
            },
        }
        d.ok = false;
        return .null;
    }

    /// The permutation that moves entries from their stored order to `Sym`
    /// order: `perm[old] = new`; `extra` identity slots follow. Null when
    /// the stored order is already that.
    fn perm(d: *De, syms: []const Sym, extra: u32) Allocator.Error!?[]u32 {
        var sorted = true;
        for (1..@max(syms.len, 1)) |i| if (@backingInt(syms[i - 1]) >= @backingInt(syms[i])) {
            sorted = false;
        };
        if (sorted) return null;
        const order = try d.a.alloc(u32, syms.len);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        std.sort.pdq(u32, order, syms, struct {
            fn lt(ss: []const Sym, x: u32, y: u32) bool {
                return @backingInt(ss[x]) < @backingInt(ss[y]);
            }
        }.lt);
        const p = try d.a.alloc(u32, syms.len + extra);
        for (order, 0..) |old, new| p[old] = @intCast(new);
        for (syms.len..p.len) |i| p[i] = @intCast(i);
        return p;
    }

    /// A frame of `n` slots, or `n` more slots of the innermost one when
    /// `extend`; the slot the new ones start at.
    fn openFrame(d: *De, extend: bool, n: u32, p: ?[]const u32) Allocator.Error!u32 {
        if (extend and d.frames.items.len > 0) return d.frames.items[d.frames.items.len - 1].extend(d.a, n, p);
        var f: Frame = .{ .slots = n };
        if (p) |q| {
            f.perm = .empty;
            try f.perm.?.appendSlice(d.a, q);
        }
        try d.frames.append(d.a, f);
        return 0;
    }

    fn closeFrame(d: *De, extend: bool, at: u32) void {
        if (extend) {
            if (d.frames.items.len > 0) d.frames.items[d.frames.items.len - 1].truncate(at);
        } else _ = d.frames.pop();
    }

    fn frameOf(d: *De, depth: u32) ?*Frame {
        if (depth >= d.frames.items.len) return null;
        return &d.frames.items[d.frames.items.len - 1 - depth];
    }

    /// A binding frame with the binds in `Sym` order. `sorted` frames (`let`,
    /// `rec`) are pushed while their values and `from` expressions load; a
    /// plain set's `inherit (e)` selects load under the from-env instead.
    /// With `extend`, a `let` whose slots extend the innermost frame.
    fn binds(d: *De, sorted: bool, extend: bool) Allocator.Error!struct { []const ir.Bind, []const ir.Ref, u32 } {
        const n = d.count();
        const syms = try d.a.alloc(Sym, n);
        const poss = try d.a.alloc(Pos, n);
        const scopes = try d.a.alloc(ir.BindScope, n);
        for (syms, poss, scopes) |*s, *p, *sc| {
            s.* = d.sym();
            p.* = d.pos();
            sc.* = std.enums.fromInt(ir.BindScope, d.u8_()) orelse blk: {
                d.ok = false;
                break :blk .own;
            };
        }
        const nfrom = d.count();
        // a `from` bind is evaluated in the env of the `from` thunks, which
        // `inheritEnv` does not make for an empty `from` list
        if (nfrom == 0) for (scopes) |sc| if (sc == .from) {
            d.ok = false;
        };
        const p = try d.perm(syms, if (sorted) nfrom else 0);
        const at: u32 = if (sorted) try d.openFrame(extend, n + nfrom, p) else 0;
        const out = try d.alloc(ir.Bind, n);
        var slices: ?Slices = null;
        if (n >= slices_min) {
            const k = d.count();
            if (k != sliceCount(n) or 4 * k > d.data.len - @min(d.at, d.data.len)) d.ok = false;
            if (d.ok) slices = .{ .k = k, .table = d.data[d.at..][0 .. 4 * k], .start = d.at + 4 * k };
            if (d.ok) d.at += 4 * k;
        }
        const done = if (slices) |sl| !sorted and try d.bindsParallel(sl, syms, poss, scopes, nfrom, p, out) else false;
        if (!done) for (0..n) |i| {
            if (!d.ok) {
                for (out[i..]) |*o| o.* = .{ .sym = @fromBackingInt(0), .pos = .none, .scope = .own, .value = &null_node };
                break;
            }
            const v = try d.bindValue(scopes[i], sorted, extend, at, n + nfrom, nfrom, p);
            const new = if (p) |q| q[i] else i;
            out[new] = .{ .sym = syms[i], .pos = poss[i], .scope = scopes[i], .value = v };
        };
        const from = try d.alloc(ir.Ref, nfrom);
        for (from) |*f| f.* = try d.node();
        return .{ out, from, at };
    }

    /// The value of one binding, read in the scope its kind names.
    fn bindValue(d: *De, scope: ir.BindScope, sorted: bool, extend: bool, at: u32, slots: u32, nfrom: u32, p: ?[]const u32) Allocator.Error!ir.Ref {
        return switch (scope) {
            // `inherit x` reads the scope outside the binds
            .outer => if (sorted) blk: {
                var saved: ?Frame = null;
                if (extend) d.closeFrame(true, at) else saved = d.frames.pop();
                const v = try d.node();
                if (extend) _ = try d.openFrame(true, slots, p);
                if (saved) |f| try d.frames.append(d.a, f);
                break :blk v;
            } else try d.node(),
            .from => if (!sorted) blk: {
                try d.frames.append(d.a, .{ .slots = nfrom });
                defer _ = d.frames.pop();
                break :blk try d.node();
            } else try d.node(),
            .own => try d.node(),
        };
    }

    /// A plain set's values, slice by slice on idle workers, each with a
    /// reader of its own: false when there are no workers. Every slice
    /// must end where the next begins, or the entry is bad.
    fn bindsParallel(d: *De, sl: Slices, syms: []const Sym, poss: []const Pos, scopes: []const ir.BindScope, nfrom: u32, p: ?[]const u32, out: []ir.Bind) Allocator.Error!bool {
        const pool = d.ev.pool orelse return false;
        _ = pool;
        var job: SliceJob = .{ .d = d, .sl = sl, .syms = syms, .poss = poss, .scopes = scopes, .nfrom = nfrom, .p = p, .out = out };
        d.ev.runJobs(sl.k, &job, SliceJob.run);
        if (job.oom.load(.acquire)) return error.OutOfMemory;
        if (job.bad.load(.acquire)) d.ok = false;
        d.at = job.end;
        return true;
    }

    /// `nodeInner` behind a call that returns the pointer in a register,
    /// null for out of memory, its only error: an error union comes back
    /// through memory at every level of the recursion.
    fn node(d: *De) callconv(ast.inline_release) Allocator.Error!ir.Ref {
        if (builtin.mode == .debug) return d.nodeInner();
        return @call(.never_inline, nodeRaw, .{d}) orelse error.OutOfMemory;
    }

    fn nodeRaw(d: *De) ?ir.Ref {
        return @call(.always_inline, nodeInner, .{d}) catch null;
    }

    fn nodeInner(d: *De) Allocator.Error!ir.Ref {
        // only the node right after the params of a lambda is its body
        const body_of = d.body_of;
        d.body_of = null;
        if (!d.ok or d.nest >= max_nest) {
            d.ok = d.ok and d.nest < max_nest;
            return &null_node;
        }
        const tag = std.enums.fromInt(std.meta.Tag(Ir), d.u8_()) orelse {
            d.ok = false;
            return &null_node;
        };
        d.nest += 1;
        defer d.nest -= 1;
        const r: Ir = switch (tag) {
            .constant => .{ .constant = d.word() catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => blk: {
                    d.ok = false;
                    break :blk .null;
                },
            } },
            .local => blk: {
                const depth = d.u32_();
                const idx = d.u32_();
                // the slot is read without a bounds check at evaluation
                // time, so the frame it lands in decides it here
                const f = d.frameOf(depth) orelse {
                    d.ok = false;
                    break :blk .{ .constant = .null };
                };
                const slot = if (f.perm) |q| (if (idx < q.items.len) q.items[idx] else std.math.maxInt(u32)) else idx;
                if (slot >= f.slots) {
                    d.ok = false;
                    break :blk .{ .constant = .null };
                }
                break :blk .{ .local = .{ .depth = depth, .idx = slot } };
            },
            .with_var => blk: {
                const s = d.sym();
                const withs = try d.alloc(u32, d.count());
                for (withs) |*w| w.* = d.u32_();
                // each names a `with` env whose slot 0 the lookup reads, in
                // rising depth
                for (withs, 0..) |w, i| {
                    if (i > 0 and withs[i - 1] >= w) d.ok = false;
                    if (d.frameOf(w)) |f| {
                        if (!f.with) d.ok = false;
                    } else d.ok = false;
                }
                break :blk .{ .with_var = .{ .sym = s, .withs = withs, .pos = d.pos() } };
            },
            .cur_pos => .{ .cur_pos = d.pos() },
            .concat => blk: {
                const fs = d.flag();
                const parts = try d.nodes();
                break :blk .{ .concat = .{ .force_string = fs, .parts = parts, .pos = d.pos() } };
            },
            .search_path => blk: {
                const name = try d.node();
                break :blk .{ .search_path = .{ .name = name, .pos = d.pos() } };
            },
            .select => blk: {
                const subject = try d.node();
                const path = try d.elems();
                const default = try d.optNode();
                const sel = try d.ev.local.arena.create(ir.Select);
                sel.* = .{ .subject = subject, .path = path, .default = default, .pos = d.pos() };
                break :blk .{ .select = sel };
            },
            .select_count => blk: {
                const subject = try d.node();
                const path = try d.elems();
                const default = try d.optNode();
                const sel = try d.ev.local.arena.create(ir.Select);
                sel.* = .{ .subject = subject, .path = path, .default = default, .pos = d.pos() };
                break :blk .{ .select_count = sel };
            },
            .select1 => blk: {
                const subject = try d.node();
                const s = d.sym();
                const default = try d.optNode();
                break :blk .{ .select1 = .{ .subject = subject, .sym = s, .default = default, .pos = d.pos() } };
            },
            .has_attr => blk: {
                const subject = try d.node();
                break :blk .{ .has_attr = .{ .subject = subject, .path = try d.elems() } };
            },
            .attrs => blk: {
                const rec = d.flag();
                const p = d.pos();
                const bs, const from, _ = try d.binds(rec, false);
                const dynamic = try d.alloc(ir.DynBind, d.count());
                for (dynamic) |*x| {
                    const name = try d.node();
                    const v = try d.node();
                    x.* = .{ .name = name, .value = v, .pos = d.pos() };
                }
                if (rec) _ = d.frames.pop();
                var overrides: ?u32 = null;
                if (rec) {
                    const ov = try d.ev.interner.intern("__overrides");
                    for (bs, 0..) |b, i| if (b.sym == ov) {
                        overrides = @intCast(i);
                    };
                }
                const a = try d.ev.local.arena.create(ir.Attrs);
                a.* = .{ .rec = rec, .pos = p, .binds = bs, .from = from, .dynamic = dynamic, .overrides = overrides };
                break :blk .{ .attrs = a };
            },
            .list => .{ .list = try d.nodes() },
            .lambda => .{ .lambda = try d.lambda(body_of) },
            .apply => blk: {
                const func = try d.node();
                const args = try d.nodes();
                break :blk .{ .apply = .init(func, args, d.pos()) };
            },
            .let => blk: {
                const extend = if (body_of) |n| n > 0 else false;
                const bs, const from, const at = try d.binds(true, extend);
                const body = try d.node();
                d.closeFrame(extend, at);
                const l = try d.ev.local.arena.create(ir.Let);
                l.* = .{ .binds = bs, .from = from, .body = body, .base = if (extend) at else ir.Let.own_env };
                break :blk .{ .let = l };
            },
            .with => blk: {
                const scope = try d.node();
                try d.frames.append(d.a, .{ .slots = 1, .with = true });
                const body = try d.node();
                _ = d.frames.pop();
                break :blk .{ .with = .{ .scope = scope, .body = body, .pos = d.pos() } };
            },
            .@"if" => blk: {
                const cond = try d.node();
                const then = try d.node();
                const br = try d.ev.local.arena.create([2]ir.Ref);
                br.* = .{ then, try d.node() };
                break :blk .{ .@"if" = .{ .cond = cond, .branches = br, .pos = d.pos() } };
            },
            .assert => blk: {
                const cond = try d.node();
                const body = try d.node();
                break :blk .{ .assert = .{ .cond = cond, .body = body, .pos = d.pos() } };
            },
            .not => blk: {
                const e = try d.node();
                break :blk .{ .not = .{ .e = e, .pos = d.pos() } };
            },
            .neg => blk: {
                const e = try d.node();
                break :blk .{ .neg = .{ .e = e, .pos = d.pos() } };
            },
            .binop => blk: {
                const op = std.enums.fromInt(ir.BinOp, d.u8_()) orelse {
                    d.ok = false;
                    break :blk .{ .constant = .null };
                };
                const l = try d.node();
                const r = try d.node();
                break :blk .{ .binop = .{ .op = op, .a = l, .b = r, .pos = d.pos() } };
            },
            .import_file => blk: {
                d.ok = false;
                break :blk .{ .constant = .null };
            },
        };
        return d.create(r);
    }

    /// A lambda; its frame extends the innermost one when it is the body
    /// of a lambda whose frame has slots (`compile.lambdaBody`).
    fn lambda(d: *De, body_of: ?u32) Allocator.Error!*const ir.Lambda {
        const extend = if (body_of) |n| n > 0 else false;
        const ptag = std.enums.fromInt(ParamTag, d.u8_()) orelse blk: {
            d.ok = false;
            break :blk .ident;
        };
        const framed = ptag != .ident_no_env;
        var at: u32 = 0;
        var end: u32 = 0;
        var param: ir.Param = .ident;
        if (ptag != .formals) {
            if (framed) {
                at = try d.openFrame(extend, 1, null);
                end = at + 1;
            }
        } else {
            const has_bind = d.flag();
            const ellipsis = d.flag();
            const n = d.count();
            const syms = try d.a.alloc(Sym, n);
            const poss = try d.a.alloc(Pos, n);
            for (syms, poss) |*s, *p| {
                s.* = d.sym();
                p.* = d.pos();
            }
            const fperm = try d.perm(syms, 0);
            const off: u32 = @intFromBool(has_bind);
            var p: ?[]u32 = null;
            if (fperm) |fp| {
                p = try d.a.alloc(u32, n + off);
                if (has_bind) p.?[0] = 0;
                for (fp, p.?[off..]) |x, *y| y.* = x + off;
            }
            at = try d.openFrame(extend, n + off, p);
            end = at + n + off;
            const formals = try d.alloc(ir.Formal, n);
            for (0..n) |i| {
                const default = try d.optNode();
                const new = if (fperm) |fp| fp[i] else i;
                formals[new] = .{ .sym = syms[i], .pos = poss[i], .default = default };
            }
            param = .{ .formals = .{ .has_bind = has_bind, .ellipsis = ellipsis, .formals = formals } };
        }
        if (framed) d.body_of = end;
        const body = try d.node();
        if (framed) d.closeFrame(extend, at);
        const p = d.pos();
        const name = d.optSym();
        const arg = d.optSym();
        const frame = switch (body.*) {
            .let => |l| if (l.base != ir.Let.own_env) l.base + @as(u32, @intCast(l.binds.len + l.from.len)) else end,
            else => end,
        };
        const l = try d.ev.local.arena.create(ir.Lambda);
        l.* = .{ .param = param, .body = body, .pos = p, .name = name, .arg = arg, .no_env = !framed, .base = if (framed) at else 0, .frame = if (framed) frame else 0 };
        return l;
    }
};

/// What an entry holds: the IR, the lint warnings of its compile (messages
/// in `ev.gpa`, the caller's), and the file's allow table (`ev.gpa`).
pub const Loaded = struct {
    code: ir.Ref,
    diags: std.ArrayList(lint.Diag),
    allows: Allows,

    /// Frees what the caller did not take.
    pub fn deinit(l: *Loaded, gpa: Allocator) void {
        for (l.diags.items) |dg| gpa.free(dg.msg);
        l.diags.deinit(gpa);
        l.allows.deinit(gpa);
    }
};

/// The IR of an entry, in the evaluator's arena with positions rebased at
/// `base`; null for a malformed entry, which the caller discards. `span` is
/// the length of the source.
pub fn deserialize(ev: *Evaluator, data: []const u8, base: u32, span: u32) Allocator.Error!?Loaded {
    if (data.len < magic.len or !std.mem.eql(u8, data[0..magic.len], magic)) return null;
    defer ev.local.compile_scratch.reset();
    var d: De = .{ .ev = ev, .a = ev.local.compile_scratch.allocator(), .data = data, .at = magic.len, .base = base, .span = span, .budget = data.len };
    const syms = try d.a.alloc(Sym, d.count());
    for (syms) |*s| {
        const name = d.bytes();
        s.* = try ev.interner.intern(name);
    }
    d.syms = syms;
    var out: Loaded = .{ .code = undefined, .diags = .empty, .allows = .{} };
    errdefer out.deinit(ev.gpa);
    for (0..d.count()) |_| {
        const id = lint.LintId.fromByte(d.u8_()) orelse {
            d.ok = false;
            break;
        };
        const p = d.pos();
        const msg = try ev.gpa.dupe(u8, d.bytes());
        out.diags.append(ev.gpa, .{ .id = id, .pos = p, .msg = msg }) catch |e| {
            ev.gpa.free(msg);
            return e;
        };
    }
    const nlines = d.count();
    try out.allows.lines.ensureTotalCapacity(ev.gpa, nlines);
    for (0..nlines) |_| out.allows.lines.appendAssumeCapacity(.{ .start = d.u32_(), .end = d.u32_(), .mask = d.u64_() });
    if (!Allows.validSorted(out.allows.lines.items)) d.ok = false;
    if (d.ok) out.code = try d.node();
    if (!d.ok or d.at != data.len) {
        out.deinit(ev.gpa);
        return null;
    }
    return out;
}
