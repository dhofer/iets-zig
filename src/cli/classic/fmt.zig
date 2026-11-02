//! `nix fmt` (src/nix/formatter.cc): the `formatter.<system>` of the flake
//! in the working directory, built once and kept alive by a link in iets's
//! roots store, then exec'd with the arguments the user gave. See
//! `docs/reference/classic.md`.

const std = @import("std");
const errors = @import("../../errors.zig");
const Allocator = std.mem.Allocator;
const Diag = @import("../../diag.zig").Diag;
const Evaluator = @import("../../eval/Evaluator.zig");
const process = @import("../../sys/process.zig");
const remote = @import("../../remote.zig");
const worker = remote.worker;
const Transport = worker.Transport;
const plan_mod = remote.plan;
const StorePath = @import("../../store/path.zig").StorePath;
const api = @import("../../api.zig");
const apibuild = api.build;
const installable = api.installable;
const Provenance = @import("../../provenance.zig").Provenance;
const devenv = @import("../devenv.zig");
const classic = @import("mod.zig");
const nix = @import("nix.zig");
const Cmd = classic.Cmd;
const Stop = classic.Stop;
const Common = classic.Common;
const Argv = classic.Argv;

const Fmt = struct {
    c: Common = .{},
    /// What is forwarded to the formatter; the first `--` is dropped.
    args: std.ArrayList([]const u8) = .empty,
};

/// args.cc:Args::parse: the first `--` is consumed and everything after it
/// is an argument, flags included.
fn parse(k: *Cmd, argv: []const []const u8) Stop!Fmt {
    var f: Fmt = .{};
    var a: Argv = .{ .k = k, .all = argv };
    var dash_dash = false;
    while (a.i < argv.len) : (a.i += 1) {
        const s = argv[a.i];
        if (!dash_dash and std.mem.eql(u8, s, "--")) {
            dash_dash = true;
        } else if (!dash_dash and s.len > 0 and s[0] == '-') {
            if (!try nix.globalFlag(&f.c, &a, s)) return k.fallBack("'{s}' is not implemented", .{s});
        } else try f.args.append(k.arena, s);
    }
    return f;
}

/// `nix fmt [ARGS...]`; `rest` is the arguments after the subcommand.
pub fn main(k: *Cmd, rest: []const []const u8) Stop!u8 {
    var f = try parse(k, rest);
    // the builder builds it and the out-link brings the closure back, so the
    // formatter runs from the local store (docs/reference/classic.md)
    const st = try nix.nixSettings(k, &f.c, false, true);
    // formatter.cc: the installable is always `.`, never an argument
    const flake_dir = try classic.cwd(k);
    const attr = try std.fmt.allocPrint(k.arena, "formatter.{s}", .{st.cfg.system()});
    const link = try outLink(k, flake_dir, attr);
    const ea = try k.arena.create(api.EvalArgs);
    ea.* = .{ .input = .{ .flake = "." }, .attr = attr, .includes = f.c.flags.includes.items, .pure = f.c.flags.pure };
    var r = try classic.run(k, &f.c, st.cfg, ea);
    classic.openCache(k, &r, ea, "fmt", &.{});
    defer if (r.cache) |c| c.deinit();
    if (r.cache != null) {
        const store = try classic.inputStore(k, ea.cache_dir);
        defer store.deinit();
        if (classic.hitResult(k, &r, store)) |bytes| if (Built.decode(bytes)) |hit| if (usable(k, hit)) {
            keep(k, link, hit.out_path);
            return k.exit(exec(k, hit.program, f.args.items, flake_dir));
        };
    }
    var job: Job = .{ .k = k, .attr = attr, .dir = flake_dir, .transport = &st.transport, .options = st.options, .cache = r.cache };
    const code = try classic.ran(k, r.go(&job, Job.go));
    if (code != 0) return code;
    const app = job.app.?;
    keep(k, link, app.out_path);
    return k.exit(exec(k, app.program, f.args.items, flake_dir));
}

/// What a run remembers: the output that holds the formatter and the
/// program inside it. Neither can hold a newline.
const Built = struct {
    out_path: []const u8,
    program: []const u8,

    fn decode(bytes: []const u8) ?Built {
        if (!std.unicode.utf8ValidateSlice(bytes)) return null;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        const out_path = lines.next() orelse return null;
        const program = lines.next() orelse return null;
        // `str::lines` ends at a final newline: a missing second line is none
        if (program.len == 0 and lines.next() == null) return null;
        return .{ .out_path = out_path, .program = program };
    }
};

/// A cache hit is usable while the program is still there. A cache directory
/// is writable by whoever runs iets, so the entry may only ever name a
/// program inside the output it remembered, and that output must be a path
/// of the store directory: a planted entry can then point `nix fmt` at no
/// file of its choosing. What the store holds under that name is the
/// daemon's to say.
fn usable(k: *Cmd, hit: Built) bool {
    if (!@import("../../cachefs.zig").programOfOutput(hit.out_path, hit.program)) return false;
    std.Io.Dir.cwd().access(k.s.io, hit.program, .{}) catch return false;
    return true;
}

/// Where the root of this flake's formatter lives: one link in iets's roots
/// store, named by the flake directory and the attribute it holds, so two
/// flakes on one machine keep two roots. Null when no home is known, which
/// costs the root and nothing else.
fn outLink(k: *Cmd, dir: []const u8, attr: []const u8) Stop!?[]const u8 {
    return devenv.rootLink(k.arena, k.c.init.environ_map, &.{ "fmt", dir, attr });
}

/// Links `out_path` in the roots store and registers the link with the
/// local daemon, whatever built it, then marks it used so the TTL sweep
/// keeps it. A root is a claim on the local store, not part of the answer:
/// when the daemon will not take one, the formatter still runs, so this warns.
fn keep(k: *Cmd, link: ?[]const u8, out_path: []const u8) void {
    const l = link orelse return;
    const s = k.s;
    var d: Diag = .init(s.gpa);
    defer d.deinit();
    const t = classic.local(k) catch return;
    const dc: devenv.Ctx = .{ .s = s, .env_map = k.c.init.environ_map, .log = .of(&s.log) };
    if (std.fs.path.dirname(l)) |dir| std.Io.Dir.cwd().createDirPath(s.io, dir) catch |e| {
        s.log.textLine(std.fmt.allocPrint(k.arena, "warning: no GC root on the formatter ({s}): cannot create {s}: {s}", .{ l, dir, @import("../../errors.zig").ioText(e) }) catch return);
        return;
    };
    devenv.ensureGcRoot(&dc, &t, l, out_path, null, &d) catch {
        s.log.textLine(std.fmt.allocPrint(k.arena, "warning: no GC root on the formatter ({s}): {s}", .{ l, d.message() }) catch return);
        return;
    };
    devenv.keepRoot(&dc, &t, l, out_path, null);
}

const Job = struct {
    k: *Cmd,
    attr: []const u8,
    dir: []const u8,
    transport: *const Transport,
    options: worker.Options,
    cache: ?*api.cache.Cache = null,
    app: ?installable.App = null,

    fn go(j: *Job, ev: *Evaluator) !u8 {
        const app = try resolve(ev, j.k.arena, j.dir, j.attr);
        j.app = app;
        if (j.cache) |c| try api.cache.writeEntry(c, j.k.s, ev, try std.fmt.allocPrint(j.k.arena, "{s}\n{s}\n", .{ app.out_path, app.program }), false);
        return j.realise(ev, app);
    }

    /// Builds the formatter and brings its closure to the local store,
    /// because the formatter runs here whatever the builder is
    /// (docs/reference/classic.md). `keep` roots what this leaves behind.
    fn realise(j: *Job, ev: *Evaluator, app: installable.App) !u8 {
        const k = j.k;
        const s = k.s;
        var d: Diag = .init(s.gpa);
        defer d.deinit();
        var inputs: apibuild.EvalInputs = .init(ev);
        defer inputs.deinit();
        const p = plan_mod.plan(s.gpa, s.io, &.{app.drv}, inputs.inputs(), &d) catch |e| return classic.report(s, &d, e);
        var prov: Provenance = .off(s.gpa);
        defer prov.deinit();
        var style: apibuild.Style = .detect(&s.log);
        style.quiet = true;
        var x = apibuild.Dispatch.open(s, k.c.init.environ_map, j.transport, j.options, p, &prov, style, &d) catch |e| return classic.report(s, &d, e);
        defer x.deinit();
        const roots = [_]installable.Root{.{ .drv = app.drv, .output = app.output }};
        _ = x.realise(k.arena, &roots, {}, struct {
            fn f(_: void, sp: *const StorePath) []const u8 {
                return sp.name();
            }
        }.f, &d) catch |e| return classic.report(s, &d, e);
        if (x.d.exit != 0) return 1;
        x.d.outLinks(&.{.{ .path = app.out_path, .link = null }}, &d) catch |e| return classic.report(s, &d, e);
        return 0;
    }
};

/// Evaluates `formatter.<system>` of the flake in `dir` and turns it into
/// an app.
fn resolve(ev: *Evaluator, a: Allocator, dir: []const u8, attr: []const u8) Evaluator.Error!installable.App {
    var d: Diag = .init(a);
    const fr = api_flake.flakeRef(a, ev.io, ".", dir, &d) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return classic.unsupported(ev, "{s}", .{d.message()}),
    };
    const outputs = try api_flake.outputs(ev, &fr);
    const found = try installable.fromOutputs(ev, a, outputs, try api_flake.url(a, &fr), .package, try std.fmt.allocPrint(a, ".{s}", .{attr}), false);
    const app = try installable.toApp(ev, a, found[0].value, attr);
    // the strings may be the evaluation's, which ends before the exec
    return .{ .drv = app.drv, .output = try a.dupe(u8, app.output), .out_path = try a.dupe(u8, app.out_path), .program = try a.dupe(u8, app.program) };
}

const api_flake = @import("../../api/flake.zig");

/// formatter.cc: the program with the user's arguments after it,
/// `PRJ_ROOT` set to the flake directory, and this process replaced by it.
fn exec(k: *Cmd, program: []const u8, args: []const []const u8, flake_dir: []const u8) u8 {
    const a = k.arena;
    const argv = a.alloc([]const u8, args.len + 1) catch return 1;
    argv[0] = program;
    @memcpy(argv[1..], args);
    var m: std.process.Environ.Map = .init(a);
    m.putAll(k.c.init.environ_map) catch return 1;
    m.put("PRJ_ROOT", flake_dir) catch return 1;
    const envp = (m.createPosixBlock(a, .{}) catch return 1).slice.ptr;
    const e = process.execvpe(a, program, argv, envp, m.get("PATH"));
    k.s.log.textLine(std.fmt.allocPrint(a, "error: unable to execute '{s}': {f}", .{ program, errors.osErrno(e) }) catch "error: unable to execute");
    return 1;
}
