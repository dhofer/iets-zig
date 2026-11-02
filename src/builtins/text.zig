//! Regular expressions, string rewriting, hashing, JSON/XML/TOML conversion,
//! rounding, `genericClosure`, and environment access.

const std = @import("std");
const Op = @import("../builtins.zig").Op;
const Evaluator = @import("../eval/Evaluator.zig");
const Error = Evaluator.Error;
const value = @import("../runtime/value.zig");
const Value = value.Value;
const Ctx = value.Ctx;
const Pos = @import("../syntax/pos.zig").Pos;
const print = @import("../eval/print.zig");
const text = @import("../syntax/text.zig");
const hash = @import("../store/hash.zig");
const Diag = @import("../diag.zig").Diag;

pub const regex = @import("text/regex.zig");
pub const json = @import("text/json.zig");
pub const toml = @import("text/toml.zig");
pub const xml = @import("text/xml.zig");

pub const ops = [_]Op{
    .{ .name = "__match", .arity = 2, .f = match },
    .{ .name = "__split", .arity = 2, .f = split },
    .{ .name = "__replaceStrings", .arity = 3, .f = replaceStrings },
    .{ .name = "__hashString", .arity = 2, .f = hashString },
    .{ .name = "__convertHash", .arity = 1, .f = convertHash },
    .{ .name = "__floor", .arity = 1, .f = floor },
    .{ .name = "__ceil", .arity = 1, .f = ceil },
    .{ .name = "__genericClosure", .arity = 1, .f = genericClosure },
    .{ .name = "__getEnv", .arity = 1, .f = getEnv },
    .{ .name = "break", .arity = 1, .f = break_ },
    .{ .name = "__toJSON", .arity = 1, .f = json.toJson },
    .{ .name = "__fromJSON", .arity = 1, .f = json.fromJson },
    .{ .name = "__toXML", .arity = 1, .f = xml.toXml },
    .{ .name = "fromTOML", .arity = 1, .f = toml.fromToml },
};

test {
    std.testing.refAllDecls(@This());
}

// Regular expressions.

/// One compiled ERE, or why Nix would reject it; the cache keeps the
/// rejection so a repeated bad pattern is not re-parsed.
const Compiled = union(enum) {
    prog: regex.Prog,
    err: regex.Error,
};

/// Patterns compile the same way in every evaluation, so the cache lives as
/// long as the process, on an allocator of its own.
var regex_cache: std.StringHashMapUnmanaged(*const Compiled) = .empty;
/// Every worker matches; the compiled patterns are read-only once made.
var regex_lock: std.Io.Mutex = .init;
const cache_gpa = std.heap.smp_allocator;

/// Entries in the regex cache.
pub fn regexCacheLen() usize {
    return regex_cache.count();
}

fn getRegex(io: std.Io, re: []const u8) Error!*const Compiled {
    regex_lock.lockUncancelable(io);
    defer regex_lock.unlock(io);
    if (regex_cache.get(re)) |c| return c;
    const c = try cache_gpa.create(Compiled);
    errdefer cache_gpa.destroy(c);
    c.* = if (regex.compile(cache_gpa, re)) |p| .{ .prog = p } else |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid, error.TooBig => |r| .{ .err = r },
    };
    const key = try cache_gpa.dupe(u8, re);
    try regex_cache.put(cache_gpa, key, c);
    return c;
}

/// The compiled pattern, or Nix's error for it. Called before the string is
/// forced, as prim_match and prim_split do: a bad pattern is an error even
/// where forcing the string would throw one `tryEval` catches.
fn compiledRegex(ev: *Evaluator, re: []const u8, pos: Pos) Error!*const regex.Prog {
    const c = try getRegex(ev.io, re);
    switch (c.*) {
        .prog => |*p| return p,
        .err => |e| {
            const what = switch (e) {
                error.Invalid => "invalid regular expression",
                error.TooBig => "memory limit exceeded by regular expression",
            };
            return ev.fail(.eval, pos, "{s} '{f}'", .{ what, text.lossy(re) });
        },
    }
}

fn groupList(ev: *Evaluator, ex: *const regex.Exec, hay: []const u8) Error!Value {
    const out = try ev.allocList(ex.ngroups());
    for (out.raw(), 0..) |*c, i| {
        c.* = .init(if (ex.group(i)) |g| try ev.mkStringStatic(hay[g.start..g.end], &.{}) else .null);
    }
    return .fromPtr(.ptr, out);
}

fn match(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const re = try ev.forceStringNoCtx(args[0], pos, "while evaluating the first argument passed to builtins.match");
    const prog = try compiledRegex(ev, re, pos);
    const s = try ev.forceString(args[1], pos, "while evaluating the second argument passed to builtins.match");
    var ex: regex.Exec = try .init(ev.gpa, prog, s.bytes());
    defer ex.deinit();
    if (!try ex.matchExact()) return .null;
    return groupList(ev, &ex, s.bytes());
}

/// `std::cregex_iterator` order: after an empty match the search resumes one
/// byte later; after a non-empty match it resumes at the match end, so an
/// empty match directly after a non-empty one is reported.
fn split(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const re = try ev.forceStringNoCtx(args[0], pos, "while evaluating the first argument passed to builtins.split");
    const prog = try compiledRegex(ev, re, pos);
    const sv = try ev.force(args[1]);
    const s = try ev.forceString(sv, pos, "while evaluating the second argument passed to builtins.split");
    const hay = s.bytes();
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(ev.gpa);
    var it: regex.Matches = try .init(ev.gpa, prog, hay);
    defer it.deinit();
    var prev_end: usize = 0;
    while (try it.next()) |m| {
        try items.append(ev.gpa, try ev.mkStringStatic(hay[prev_end..m.start], &.{}));
        try items.append(ev.gpa, try groupList(ev, &it.exec, hay));
        prev_end = m.end;
    }
    if (items.items.len == 0) return ev.mkList(&.{sv});
    try items.append(ev.gpa, try ev.mkStringStatic(hay[prev_end..], &.{}));
    return ev.mkList(items.items);
}

// String rewriting.

fn replaceStrings(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const from_l = try ev.forceList(args[0], pos, "while evaluating the first argument passed to builtins.replaceStrings");
    const to_l = try ev.forceList(args[1], pos, "while evaluating the second argument passed to builtins.replaceStrings");
    if (from_l.len != to_l.len)
        return ev.fail(.eval, pos, "'from' and 'to' arguments passed to builtins.replaceStrings have different lengths", .{});
    const from = try ev.gpa.alloc([]const u8, from_l.len);
    defer ev.gpa.free(from);
    for (from_l.cells(), from) |*c, *f| {
        f.* = (try ev.forceString(c.get(), pos, "while evaluating one of the strings to replace passed to builtins.replaceStrings")).bytes();
    }
    const sv = try ev.force(args[2]);
    const s = try ev.forceString(sv, pos, "while evaluating the third argument passed to builtins.replaceStrings");
    if (from.len == 0) return sv;
    const bytes = s.bytes();
    var ctx: std.ArrayList(Ctx) = .empty;
    defer ctx.deinit(ev.gpa);
    try ctx.appendSlice(ev.gpa, s.context());
    // The replacements are forced the first time they are used, and only then.
    const to = try ev.gpa.alloc(?*value.String, from.len);
    defer ev.gpa.free(to);
    @memset(to, null);
    var res: std.ArrayList(u8) = .empty;
    defer res.deinit(ev.gpa);
    try res.ensureTotalCapacity(ev.gpa, bytes.len);
    var p: usize = 0;
    // One past the end, so an empty `from` also matches after the last byte.
    while (p <= bytes.len) {
        const j = for (from, 0..) |f, j| {
            if (std.mem.startsWith(u8, bytes[p..], f)) break j;
        } else null;
        if (j) |k| {
            const t = to[k] orelse blk: {
                const t = try ev.forceString(to_l.cells()[k].get(), pos, "while evaluating one of the replacement strings passed to builtins.replaceStrings");
                try ctx.appendSlice(ev.gpa, t.context());
                to[k] = t;
                break :blk t;
            };
            try res.appendSlice(ev.gpa, t.bytes());
            if (from[k].len > 0) {
                p += from[k].len;
                continue;
            }
        }
        if (p < bytes.len) try res.append(ev.gpa, bytes[p]);
        p += 1;
    }
    return ev.mkStringCtx(res.items, ctx.items);
}

// Hashes.

pub fn parseAlgo(ev: *Evaluator, v: Value, pos: Pos, ctx: []const u8) Error!hash.Algo {
    const name = try ev.forceStringNoCtx(v, pos, ctx);
    return hash.Algo.parse(name) orelse ev.fail(.eval, pos, "unknown hash algorithm '{f}'", .{text.lossy(name)});
}

fn hashString(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const algo = try parseAlgo(ev, args[0], pos, "while evaluating the first argument passed to builtins.hashString");
    const s = try ev.forceString(args[1], pos, "while evaluating the second argument passed to builtins.hashString");
    const h = hash.hashBytes(algo, s.bytes());
    var buf: [hash.Hash.max_string_len]u8 = undefined;
    return ev.mkString(h.print(&buf, .base16, false));
}

fn missingAttr(ev: *Evaluator, name: []const u8, pos: Pos, comptime ctx: []const u8, ctx_args: anytype) Error {
    const e = ev.fail(.type, pos, "attribute '{s}' missing", .{name});
    return ev.addTrace(e, pos, ctx, ctx_args);
}

fn convertHash(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const a = try ev.forceAttrs(args[0], pos, "while evaluating the first argument passed to builtins.convertHash");
    const h = a.get(try ev.sym("hash")) orelse return missingAttr(ev, "hash", pos, "while locating the attribute 'hash'", .{});
    const hash_text = try ev.forceStringNoCtx(h.cell.get(), pos, "while evaluating the attribute 'hash'");
    const algo: ?hash.Algo = if (a.get(try ev.sym("hashAlgo"))) |x|
        try parseAlgo(ev, x.cell.get(), pos, "while evaluating the attribute 'hashAlgo'")
    else
        null;
    const f = a.get(try ev.sym("toHashFormat")) orelse return missingAttr(ev, "toHashFormat", pos, "while locating the attribute 'toHashFormat'", .{});
    const fmt = try ev.forceStringNoCtx(f.cell.get(), pos, "while evaluating the attribute 'toHashFormat'");
    const format: hash.Format = if (std.mem.eql(u8, fmt, "base16"))
        .base16
    else if (std.mem.eql(u8, fmt, "nix32"))
        .nix32
    else if (std.mem.eql(u8, fmt, "base32")) blk: {
        try ev.effect("warning: \"base32\" is a deprecated alias for hash format \"nix32\".", .{});
        break :blk .nix32;
    } else if (std.mem.eql(u8, fmt, "base64"))
        .base64
    else if (std.mem.eql(u8, fmt, "sri"))
        .sri
    else
        return ev.fail(.eval, pos, "unknown hash format '{f}', expect 'base16', 'base32', 'base64', or 'sri'", .{text.lossy(fmt)});
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    // Hash::parse_any reads the text as UTF-8, lossily.
    var lossy: std.Io.Writer.Allocating = .init(ev.gpa);
    defer lossy.deinit();
    text.writeLossy(&lossy.writer, hash_text, null) catch return error.OutOfMemory;
    const parsed = hash.Hash.parseAny(lossy.written(), algo, &d) catch
        return ev.fail(.eval, pos, "{s}", .{d.message()});
    var buf: [hash.Hash.max_string_len]u8 = undefined;
    return ev.mkString(parsed.print(&buf, format, format == .sri));
}

// Rounding.

fn round(ev: *Evaluator, v_in: Value, pos: Pos, ctx: []const u8, comptime op: fn (f64) f64) Error!Value {
    const v = try ev.force(v_in);
    const arg_int: ?i64 = switch (v.view()) {
        .int => |i| i,
        else => null,
    };
    const x = try ev.forceFloat(v, pos, ctx);
    const r = op(x);
    const int_min: f64 = @floatFromInt(std.math.minInt(i64));
    const res: i64 = if (r >= int_min and r < -int_min)
        @intFromFloat(r)
    else if (arg_int) |i|
        return ev.fail(.eval, pos, "Due to a bug (see https://github.com/NixOS/nix/issues/12899) the NixInt argument {d} caused undefined behavior in previous Nix versions.\n\tFuture Nix versions might implement the correct behavior.", .{i})
    else {
        var buf: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        print.writeFloatG(&w, x) catch unreachable;
        return ev.fail(.eval, pos, "NixFloat argument {s} is not in the range of NixInt", .{w.buffered()});
    };
    if (arg_int) |i| if (i != res)
        return ev.fail(.eval, pos, "Due to a bug (see https://github.com/NixOS/nix/issues/12899) a loss of precision occurred in previous Nix versions because the NixInt argument {d} was rounded to {d}.\n\tFuture Nix versions might implement the correct behavior.", .{ i, res });
    return ev.mkInt(res);
}

fn floorF(x: f64) f64 {
    return @floor(x);
}

fn ceilF(x: f64) f64 {
    return @ceil(x);
}

fn floor(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    return round(ev, args[0], pos, "while evaluating the first argument passed to builtins.floor", floorF);
}

fn ceil(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    return round(ev, args[0], pos, "while evaluating the first argument passed to builtins.ceil", ceilF);
}

// genericClosure.

fn genericClosure(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const a = try ev.forceAttrs(args[0], .none, "while evaluating the first argument passed to builtins.genericClosure");
    const start = a.get(ev.s.startSet) orelse
        return missingAttr(ev, "startSet", pos, "in the attrset passed as argument to builtins.genericClosure", .{});
    const sv = try ev.force(start.cell.get());
    const sl = try ev.forceList(sv, .none, "while evaluating the 'startSet' attribute passed as argument to builtins.genericClosure");
    if (sl.len == 0) return sv;
    var work: std.ArrayList(Value) = .empty;
    defer work.deinit(ev.gpa);
    for (sl.cells()) |*c| try work.append(ev.gpa, c.get());
    const op_attr = a.get(ev.s.operator) orelse
        return missingAttr(ev, "operator", pos, "in the attrset passed as argument to builtins.genericClosure", .{});
    const op = try ev.forceFunction(op_attr.cell.get(), .none, "while evaluating the 'operator' attribute passed as argument to builtins.genericClosure");
    // The keys seen so far, ordered by `<`, like Nix's std::map<Value*, CompareValues>.
    var keys: std.ArrayList(Value) = .empty;
    defer keys.deinit(ev.gpa);
    var res: std.ArrayList(Value) = .empty;
    defer res.deinit(ev.gpa);
    var head: usize = 0;
    while (head < work.items.len) {
        const item = work.items[head];
        head += 1;
        const ea = ev.forceAttrs(item, .none, "") catch |e|
            return ev.addTrace(e, .none, "in genericClosure element", .{});
        const e: Value = .fromPtr(.ptr, ea);
        const key = ea.get(ev.s.key) orelse
            return missingAttr(ev, "key", pos, "in genericClosure element", .{});
        const kv = try ev.forceCell(&key.cell);
        var lo: usize = 0;
        var hi: usize = keys.items.len;
        const found = while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (try ev.lessThan(keys.items[mid], kv, .none)) {
                lo = mid + 1;
            } else if (try ev.lessThan(kv, keys.items[mid], .none)) {
                hi = mid;
            } else break true;
        } else false;
        if (found) continue;
        try keys.insert(ev.gpa, lo, kv);
        try res.append(ev.gpa, e);
        const new = try ev.call1(op, e, .none);
        const nl = try ev.forceList(new, .none, "while evaluating the return value of the `operator` passed to builtins.genericClosure");
        for (nl.cells()) |*c| try work.append(ev.gpa, try ev.forceCell(c));
    }
    return ev.mkList(res.items);
}

// Environment.

fn getEnv(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const name = try ev.forceStringNoCtx(args[0], pos, "while evaluating the first argument passed to builtins.getEnv");
    try @import("../lint/purity.zig").getEnv(ev, name, pos);
    if (ev.config.pure) return ev.mkStringStatic("", &.{});
    ev.trace().env(name);
    const z = try ev.gpa.dupeSentinel(u8, name, 0);
    defer ev.gpa.free(z);
    const v = std.c.getenv(z) orelse return ev.mkStringStatic("", &.{});
    return ev.mkString(std.mem.span(v));
}

fn break_(ev: *Evaluator, args: []const Value, _: Pos) Error!Value {
    return ev.force(args[0]);
}
