//! Primop registration. Each family is a file under `builtins/` exporting
//! `pub const ops: []const Op`. A name with the `__` prefix is a global under
//! that name and in `builtins` without it; a name without is both.

const std = @import("std");
const Evaluator = @import("eval/Evaluator.zig");
const Error = Evaluator.Error;
const value = @import("runtime/value.zig");
const Value = value.Value;
const import_ = @import("eval/import.zig");
const corepkgs = @import("corepkgs.zig");

pub const Op = struct {
    name: []const u8,
    arity: u8,
    f: *const Evaluator.PrimFn,
};

pub const store_hooks = @import("builtins/store_hooks.zig");
/// The derivation table and `setAttr`, for a host listing what a run made.
pub const derivation = @import("builtins/derivation.zig");

const families = .{
    @import("builtins/core.zig"),
    @import("builtins/attrs.zig"),
    @import("builtins/lists.zig"),
    @import("builtins/math.zig"),
    @import("builtins/strings.zig"),
    @import("builtins/text.zig"),
    @import("builtins/paths.zig"),
    @import("builtins/context.zig"),
    @import("builtins/derivation.zig"),
    @import("builtins/flake.zig"),
};

/// A thunk over this, so the run is marked uncacheable only when a program
/// forces it.
fn currentTime(ev: *Evaluator, _: []const Value, _: @import("syntax/pos.zig").Pos) Error!Value {
    ev.trace().markUncacheable();
    const now = std.Io.Clock.real.now(ev.io);
    return ev.mkInt(@intCast(@divFloor(now.nanoseconds, std.time.ns_per_s)));
}

fn builtinsName(name: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, name, "__")) name[2..] else name;
}

/// Whether this run puts `name` in `builtins` at all. Nix leaves three out
/// until an experimental feature is on, and code branches on whether they
/// are there: `flake-compat` takes its `fetchTree` path when `builtins ?
/// fetchTree`. Under one of Nix's own names iets answers as Nix does; its
/// own commands have every feature, which is the documented divergence.
fn exposed(ev: *const Evaluator, name: []const u8) bool {
    const s = ev.config.session orelse return true;
    if (!s.log.isClassic()) return true;
    const n = builtinsName(name);
    const eql = std.mem.eql;
    // primops.cc: `fetch-tree` or `flakes`, since the flake machinery is
    // written in Nix and calls it
    if (eql(u8, n, "fetchTree")) return s.xpOn("fetch-tree") or s.xpOn("flakes");
    if (eql(u8, n, "fetchClosure")) return s.xpOn("fetch-closure");
    if (eql(u8, n, "outputOf")) return s.xpOn("dynamic-derivations");
    return true;
}

/// Fill the globals and the `builtins` set, then evaluate `derivation.nix`.
pub fn install(ev: *Evaluator) Error!void {
    ev.root_env = try ev.allocEnv(null, 0);
    var entries: std.ArrayList(value.Attr) = .empty;
    defer entries.deinit(ev.gpa);
    inline for (families) |fam| {
        inline for (fam.ops) |op| if (exposed(ev, op.name)) {
            const v = try ev.mkPrimOp(op.name, op.arity, op.f);
            try ev.globals.put(ev.gpa, try ev.sym(op.name), v);
            try entries.append(ev.gpa, .{ .sym = try ev.sym(builtinsName(op.name)), .pos = .none, .cell = .init(v) });
        };
    }
    var consts: std.ArrayList(struct { []const u8, Value }) = .empty;
    defer consts.deinit(ev.gpa);
    try consts.appendSlice(ev.gpa, &.{
        .{ "true", .true },
        .{ "false", .false },
        .{ "null", .null },
        .{ "__nixVersion", try ev.mkString("2.34.8") },
        .{ "__langVersion", .immInt(6) },
        .{ "__storeDir", try ev.mkString(ev.store_dir) },
    });
    // eval.cc:addConstant: the impure-only ones do not exist when pure.
    if (!ev.config.pure) try consts.append(ev.gpa, .{ "__currentSystem", try ev.mkString(ev.config.system) });
    // A thunk, so the clock is read once, and only when a run asks.
    if (!ev.config.pure) try consts.append(ev.gpa, .{ "__currentTime", try ev.mkThunkApp(try ev.mkPrimOp("currentTimeRaw", 1, currentTime), .null) });
    var np: std.ArrayList(Value) = .empty;
    defer np.deinit(ev.gpa);
    for (ev.config.search_path) |e| {
        var a = [_]value.Attr{
            .{ .sym = ev.s.path, .pos = .none, .cell = .init(try ev.mkString(e.path)) },
            .{ .sym = ev.s.prefix, .pos = .none, .cell = .init(try ev.mkString(e.prefix)) },
        };
        try np.append(ev.gpa, try ev.mkAttrs(&a, .none));
    }
    try consts.append(ev.gpa, .{ "__nixPath", try ev.mkList(np.items) });
    for (consts.items) |c| {
        try ev.globals.put(ev.gpa, try ev.sym(c[0]), c[1]);
        try entries.append(ev.gpa, .{ .sym = try ev.sym(builtinsName(c[0])), .pos = .none, .cell = .init(c[1]) });
    }
    try entries.append(ev.gpa, .{ .sym = ev.s.derivation, .pos = .none, .cell = .init(.null) });
    const s_builtins = try ev.sym("builtins");
    try entries.append(ev.gpa, .{ .sym = s_builtins, .pos = .none, .cell = .init(.null) });
    const bv = try ev.mkAttrs(entries.items, .none);
    const battrs = bv.as(value.Attrs);
    battrs.get(s_builtins).?.cell.set(bv);
    try ev.globals.put(ev.gpa, s_builtins, bv);

    const code = try import_.compileSource(ev, "«derivation-internal»", corepkgs.get("derivation.nix").?, "/", null);
    const d = try ev.eval(ev.root_env, code);
    battrs.get(ev.s.derivation).?.cell.set(d);
    try ev.globals.put(ev.gpa, ev.s.derivation, d);
}

test {
    inline for (families) |fam| std.testing.refAllDecls(fam);
    _ = @import("builtins/Bits.zig");
}
