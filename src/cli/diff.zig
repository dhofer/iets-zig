//! `iets diff A B`: what differs between two derivations
//! (docs/reference/commands.md). The JSON of a diff is in `api/render.zig`, its text in `cli/render.zig`.
//!
//! A side that is a `.drv` needs nothing but the store. A side that needs an
//! evaluation goes through `api.run.Run` (`evaluate`).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = Io.Writer;
const Diag = @import("../diag.zig").Diag;
const Session = @import("../session.zig").Session;
const log_mod = @import("../log.zig");
const Report = log_mod.Report;
const errors = @import("../errors.zig");
const path_mod = @import("../store/path.zig");
const StorePath = path_mod.StorePath;
const drv_mod = @import("../store/drv.zig");
const Derivation = drv_mod.Derivation;
const drvdiff = @import("../store/drvdiff.zig");
const remote = @import("../remote.zig");
const plan = @import("../remote/plan.zig");
const help = @import("help.zig");
const args = @import("args.zig");
const api = @import("../api.zig");
const cli = @import("../cli.zig");
const worker = @import("../remote/worker.zig");
const api_render = @import("../api/render.zig");
const render = @import("render.zig");

pub const Opts = struct {
    json: bool = false,
    depth: usize = 2,
    closure: bool = false,
    builder: ?[]const u8 = null,
};

/// A side that needs an evaluation, which must give exactly one derivation.
pub const EvalSide = struct {
    input: ?api.Input,
    /// `-A`'s attribute, when the sides are `-A X -A Y`.
    attr: ?[]const u8,
};

/// One of the two things being compared: a `.drv` in the store, or an
/// evaluation.
pub const Side = union(enum) {
    drv: StorePath,
    eval: EvalSide,
};

/// The command line, parsed.
pub const Parsed = struct {
    opts: Opts,
    flags: args.EvalFlags,
    sides: [2]Side,
};

/// The two root derivations, and the evaluation's derivation table to read
/// them and their inputs from first; the rest comes from `/nix/store`.
pub const Resolved = struct {
    roots: [2]StorePath,
    inputs: plan.Inputs = .{},
};

/// `iets diff ARGS...`: 0 when the two are equal, 1 when they differ, 2 for
/// a usage error or any other failure (docs/reference/errors.md). `argv` is
/// what follows `diff`.
pub fn cmd(c: *const cli.Ctx, argv: []const []const u8) u8 {
    const s = c.s;
    s.log.command = "diff";
    const arena = c.init.arena.allocator();
    var a: args.Args = .{ .s = s, .arena = arena, .cmd = "diff", .argv = argv };
    const p = parse(&a) catch |e| return a.report(e);
    var code: u8 = 0;
    const res = resolve(c, arena, &p, &code) catch |e| return switch (e) {
        error.Reported => @max(code, 2),
        // what a failed allocation always came to
        error.OutOfMemory => 2,
    };
    var d: Diag = .init(s.gpa);
    defer d.deinit();
    return run(s, arena, &p.opts, res.inputs, res.roots, &d) catch |e| fail(s, &d, e);
}

/// Reports a failure of `run` and gives its exit code, at least 2.
fn fail(s: *Session, d: *const Diag, e: anyerror) u8 {
    return @max(errors.report(e, d).emit(&s.log), 2);
}

/// The sides, with the evaluation of those that need one.
fn resolve(c: *const cli.Ctx, arena: Allocator, p: *const Parsed, code: *u8) error{ Reported, OutOfMemory }!Resolved {
    if (p.sides[0] == .drv and p.sides[1] == .drv)
        return .{ .roots = .{ p.sides[0].drv, p.sides[1].drv } };
    return evaluate(c, arena, &p.flags, &p.sides, code);
}

/// The comparison of two resolved roots: the derivations, or with
/// `--closure` their output closures. The exit code: 0 equal, 1 different.
pub fn run(s: *Session, arena: Allocator, o: *const Opts, inputs: plan.Inputs, roots: [2]StorePath, d: *Diag) !u8 {
    var loader: Loader = .{ .io = s.io, .inputs = inputs };
    if (o.closure) return closureDiff(s, arena, o, loader.loader(), roots[0], roots[1], d);
    const df = try drvdiff.diff(s.gpa, arena, loader.loader(), roots[0], roots[1], o.depth, d);
    var out: Writer.Allocating = .init(s.gpa);
    defer out.deinit();
    if (o.json) {
        try api_render.diffJson(&out.writer, &df);
        try out.writer.writeByte('\n');
    } else try render.diffText(s.gpa, &out.writer, &df);
    try render.write(s, out.written(), d);
    return @intFromBool(!df.isEmpty());
}

/// A derivation this run evaluated, else the one in `/nix/store`.
const Loader = struct {
    io: Io,
    inputs: plan.Inputs,

    fn loader(l: *Loader) drv_mod.Loader {
        return .{ .ctx = l, .loadFn = load };
    }

    fn load(ctx: *anyopaque, arena: Allocator, p: StorePath, d: *Diag) drv_mod.Error!Derivation {
        const l: *Loader = @ptrCast(@alignCast(ctx));
        const name = try Derivation.nameFromPath(&p, d);
        if (l.inputs.getDrv(&p)) |info| if (info.aterm) |t| return Derivation.parse(arena, t, name, d);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const full = p.print(&buf);
        const text = Io.Dir.cwd().readFileAlloc(l.io, full, arena, .unlimited) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return d.fail(error.BadDerivation, "cannot read derivation '{s}': {s}{f}", .{ full, errors.ioText(e), OsError{ .e = e } }),
        };
        return Derivation.parse(arena, text, name, d);
    }
};

/// The ` (os error N)` Rust iets prints after an OS error's text, for the
/// errors a read of a file can meet.
const OsError = struct {
    e: anyerror,

    pub fn format(o: OsError, w: *Writer) Writer.Error!void {
        const n: u16 = switch (o.e) {
            error.PermissionDenied => 1,
            error.FileNotFound => 2,
            error.SystemResources => 12,
            error.AccessDenied => 13,
            error.NotDir => 20,
            error.IsDir => 21,
            error.ProcessFdQuotaExceeded => 24,
            error.NameTooLong => 36,
            error.SymLinkLoop => 40,
            else => return,
        };
        try w.print(" (os error {d})", .{n});
    }
};

// The command line

/// The flags and the sides.
fn parse(a: *args.Args) args.Error!Parsed {
    const eql = std.mem.eql;
    const s = a.s;
    var o: Opts = .{};
    var f: args.EvalFlags = .{};
    var pos: std.ArrayList([]const u8) = .empty;
    var expr: ?[]const u8 = null;
    const arena = a.arena;
    while (a.i < a.argv.len) : (a.i += 1) {
        const x = a.argv[a.i];
        if (try args.evalFlag(a, &f, x)) continue;
        if (eql(u8, x, "--json")) {
            o.json = true;
        } else if (eql(u8, x, "--all")) {
            o.depth = drvdiff.all_levels;
        } else if (eql(u8, x, "--closure")) {
            o.closure = true;
        } else if (eql(u8, x, "--builder")) {
            o.builder = try a.next(x);
        } else if (eql(u8, x, "--depth")) {
            const v = try a.next(x);
            o.depth = parseDepth(v) orelse return a.fail("--depth wants a number, got '{s}'", .{v});
        } else if (eql(u8, x, "-E") or eql(u8, x, "--expr")) {
            expr = try a.next(x);
        } else if (eql(u8, x, "-f") or eql(u8, x, "--file")) {
            // a synonym for the positional side, as for 'iets eval'
            try pos.append(arena, try a.next(x));
        } else if (x.len > 0 and x[0] == '-' and !eql(u8, x, "-")) {
            return a.unknownFlag(x);
        } else try pos.append(arena, x);
    }
    {
        var d: Diag = .init(s.gpa);
        defer d.deinit();
        s.loadNixConfNative(f.overrides.items, &d) catch {};
    }
    var sides: [2]Side = undefined;
    const n_attrs = f.attrs.items.len;
    if (n_attrs == 2 and pos.items.len <= 1) {
        const first: ?[]const u8 = if (pos.items.len == 1) pos.items[0] else null;
        for (&sides, f.attrs.items) |*side, at| side.* = try sideOf(a, first, expr, at);
    } else if (n_attrs == 0 and pos.items.len == 2) {
        for (&sides, pos.items) |*side, x| side.* = try sideOf(a, x, expr, null);
    } else return a.fail("give two derivations (A B), or one expression, file or flake with -A X -A Y", .{});
    return .{ .opts = o, .flags = f, .sides = sides };
}

/// A depth as Rust iets reads one (`usize::from_str`): decimal digits, an
/// optional `+`.
fn parseDepth(v: []const u8) ?usize {
    const digits = if (v.len > 0 and v[0] == '+') v[1..] else v;
    if (digits.len == 0) return null;
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(usize, digits, 10) catch null;
}

/// One side: the positional `p` (a .drv in the store, a flake reference or
/// a file), or `-E EXPR`, with the attribute `attr` selected.
fn sideOf(a: *args.Args, p: ?[]const u8, expr: ?[]const u8, attr: ?[]const u8) args.Error!Side {
    const s = a.s;
    if (p) |x| if (std.mem.endsWith(u8, x, ".drv")) {
        var d: Diag = .init(s.gpa);
        defer d.deinit();
        const sp = StorePath.fromBaseName(baseName(x), &d) catch
            return a.fail("{s}", .{d.message()});
        if (!sp.isDerivation()) return a.fail("'{f}' is not a derivation path", .{&sp});
        return .{ .drv = sp };
    };
    if (p != null and expr != null) return a.fail("-E and FILE cannot be combined", .{});
    const input: ?api.Input = if (p) |x|
        (if (args.isFlakeRef(s.io, x)) .{ .flake = x } else .{ .file = x })
    else if (expr) |e| .{ .expr = e } else null;
    return .{ .eval = .{ .input = input, .attr = attr } };
}

/// `/nix/store/<hash>-<name>.drv`, `./<hash>-<name>.drv` or the base name.
fn baseName(arg: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, arg, '/') orelse return arg;
    return arg[i + 1 ..];
}

/// `--closure`: the output closures compared by package name and version,
/// as nvd does. The daemon answers what each path refers to.
fn closureDiff(s: *Session, arena: Allocator, o: *const Opts, load: drv_mod.Loader, a: StorePath, b: StorePath, d: *Diag) !u8 {
    // the closure is read where the outputs are, so this is the local daemon
    // and not the `builder` setting
    const url = o.builder orelse "daemon";
    const t = worker.Transport.parse(arena, url, s.env.map) orelse
        return d.fail(error.Usage, "unsupported store '{s}': expected daemon, unix:///path or ssh-ng://[user@]host", .{url});
    const conn = try worker.Connection.open(s.gpa, s.io, &t, s.env.map, .of(&s.log), .ignore, d);
    defer conn.close();
    const ca = try closure(arena, conn, load, a, d);
    const cb = try closure(arena, conn, load, b, d);
    const c = try api_render.Closure.of(arena, try std.fmt.allocPrint(arena, "{f}", .{&a}), try std.fmt.allocPrint(arena, "{f}", .{&b}), ca, cb);
    var out: Writer.Allocating = .init(s.gpa);
    defer out.deinit();
    if (o.json) {
        try c.json(&out.writer);
        try out.writer.writeByte('\n');
    } else try render.closureText(&out.writer, &c);
    try render.write(s, out.written(), d);
    return @intFromBool(!c.isEmpty());
}

/// The versions of each package name in the closure of every output of the
/// derivation `p`.
fn closure(arena: Allocator, conn: *worker.Connection, load: drv_mod.Loader, p: StorePath, d: *Diag) !api_render.Versions {
    const drv = try load.load(arena, p, d);
    var todo: std.ArrayList([]const u8) = .empty;
    for (drv.outputs) |out| if (try drv.outputPath(out.name, d)) |sp|
        try todo.append(arena, try std.fmt.allocPrint(arena, "{f}", .{&sp}));
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var pairs: std.ArrayList(api_render.NameVersion) = .empty;
    while (todo.pop()) |path| {
        if ((try seen.fetchPut(arena, path, {})) != null) continue;
        const info = try conn.queryPathInfo(arena, path, .ignore, d) orelse {
            const hint = try std.fmt.allocPrint(arena, "build it first: iets build {f}", .{&p});
            return d.failHint(error.Store, hint, "'{s}' is not in the store", .{path});
        };
        const nv = nameVersion(baseName(path));
        try pairs.append(arena, .{ .name = nv[0], .version = nv[1] });
        for (info.references) |r| if (!seen.contains(r)) try todo.append(arena, r);
    }
    return api_render.Versions.of(arena, pairs.items);
}

/// `<hash>-NAME-VERSION`: the name ends at the first dash before a digit,
/// as Nix's `parseDrvName` and nvd split it.
pub fn nameVersion(base: []const u8) [2][]const u8 {
    const n = if (base.len >= path_mod.hash_part_len + 1) base[path_mod.hash_part_len + 1 ..] else base;
    var i: usize = 0;
    while (i + 1 < n.len) : (i += 1) {
        if (n[i] == '-' and std.ascii.isDigit(n[i + 1])) return .{ n[0..i], n[i + 1 ..] };
    }
    return .{ n, "" };
}

// Tests

const testing = std.testing;

test "a name ends at the first dash before a digit" {
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-hello-2.12.1", "hello", "2.12.1" },
        .{ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bash-interactive-5.2", "bash-interactive", "5.2" },
        .{ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-source", "source", "" },
    };
    for (cases) |c| {
        const nv = nameVersion(c[0]);
        try testing.expectEqualStrings(c[1], nv[0]);
        try testing.expectEqualStrings(c[2], nv[1]);
    }
}

test "a flag is suggested within a third of its length" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const names = help.flagNames("diff");
    try testing.expectEqualStrings("--json", (try help.suggest(arena.allocator(), "--jsn", names)).?);
    try testing.expectEqual(null, try help.suggest(arena.allocator(), "--bogus", names));
    // --depth --all --json --closure --builder -f --file -I --arg --argstr
    // --option --impure --log-format --show-trace
    try testing.expectEqual(14, names.len);
}

test "the depth is a decimal number" {
    try testing.expectEqual(3, parseDepth("3"));
    try testing.expectEqual(3, parseDepth("+3"));
    try testing.expectEqual(null, parseDepth("-1"));
    try testing.expectEqual(null, parseDepth("x"));
    try testing.expectEqual(null, parseDepth(""));
}

/// The evaluating sides through the evaluator: the
/// first evaluating side's flags are the run's; each side must give exactly
/// one derivation (else the usage error "each side must be one derivation,
/// this one is N"). The ATerms the evaluation made are copied out, so the
/// comparison reads them after the evaluator is gone. A failure is reported,
/// its exit code in `code`.
fn evaluate(c: *const cli.Ctx, arena: Allocator, flags: *const args.EvalFlags, sides: *const [2]Side, code: *u8) error{ Reported, OutOfMemory }!Resolved {
    const s = c.s;
    var evals: [2]api.EvalArgs = undefined;
    var first: ?usize = null;
    for (sides, &evals, 0..) |side, *ea, i| switch (side) {
        .drv => {},
        .eval => |e| {
            ea.* = .{
                .includes = flags.includes.items,
                .args = flags.args.items,
                .pure = flags.pure,
                .attr = e.attr,
                .input = e.input,
                .no_tracing_cache = !s.settings.cache,
                .no_ir_cache = !s.settings.cache,
            };
            if (first == null) first = i;
        },
    };
    const Job = struct {
        c: *const cli.Ctx,
        arena: Allocator,
        sides: *const [2]Side,
        evals: *const [2]api.EvalArgs,
        table: *api.build.DrvTable,
        roots: [2]StorePath = undefined,
        fn go(j: *@This(), ev: *@import("../eval/Evaluator.zig")) !u8 {
            const cwd = std.process.currentPathAlloc(j.c.init.io, j.arena) catch "/";
            for (j.sides, j.evals, &j.roots) |side, *ea, *root| switch (side) {
                .drv => |p| root.* = p,
                .eval => {
                    if (ea.input == null) {
                        const r: Report = .{ .code = "usage", .raw = "nothing to evaluate: give -E EXPR or FILE", .hint = "run 'iets diff --help' for the flags" };
                        return r.emit(&j.c.s.log);
                    }
                    const v = try api.evaluate(ev, j.arena, ea, cwd);
                    var found: std.ArrayList(api.installable.DrvRoot) = .empty;
                    try api.installable.drvRoots(ev, j.arena, v, &found);
                    if (found.items.len != 1) {
                        const msg = try std.fmt.allocPrint(j.arena, "each side must be one derivation, this one is {d}", .{found.items.len});
                        const r: Report = .{ .code = "usage", .raw = msg };
                        return r.emit(&j.c.s.log);
                    }
                    root.* = found.items[0].drv;
                },
            };
            ev.shared.drv_lock.lock(ev);
            defer ev.shared.drv_lock.unlock(ev);
            var it = ev.shared.drv.table.iterator();
            var d: Diag = .init(j.arena);
            while (it.next()) |e| {
                const aterm = e.value_ptr.aterm orelse continue;
                const p = try StorePath.fromBaseName(e.key_ptr.*, &d);
                try j.table.add(p, aterm, &d);
            }
            return 0;
        }
    };
    const table = try arena.create(api.build.DrvTable);
    table.* = .init(arena);
    var job: Job = .{ .c = c, .arena = arena, .sides = sides, .evals = &evals, .table = table };
    const r: api.run.Run = .{ .s = s, .init = c.init, .args = &evals[first.?] };
    code.* = r.go(&job, Job.go);
    if (code.* != 0) return error.Reported;
    return .{ .roots = job.roots, .inputs = table.inputs() };
}
