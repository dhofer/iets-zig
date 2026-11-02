//! `nix-instantiate` (nix-instantiate.cc). Evaluates, registers the
//! derivation closure through the daemon and prints the drv paths, or
//! evaluates and prints the value with `--eval`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Diag = @import("../../diag.zig").Diag;
const Evaluator = @import("../../eval/Evaluator.zig");
const print = @import("../../eval/print.zig");
const value = @import("../../runtime/value.zig");
const Value = value.Value;
const remote = @import("../../remote.zig");
const worker = remote.worker;
const Transport = worker.Transport;
const plan_mod = remote.plan;
const StorePath = @import("../../store/path.zig").StorePath;
const api = @import("../../api.zig");
const apibuild = api.build;
const installable = api.installable;
const Root = installable.Root;
const Provenance = @import("../../provenance.zig").Provenance;
const cli = @import("../../cli.zig");
const classic = @import("mod.zig");
const Cmd = classic.Cmd;
const Stop = classic.Stop;
const Common = classic.Common;
const Argv = classic.Argv;

const name = "nix-instantiate";

/// shared.cc:printGCWarning, which fires at the first derivation.
const gc_warning = "warning: you did not specify '--add-root'; the result might be removed by the garbage collector";

const Output = enum { plain, raw, json };

const Inst = struct {
    c: Common = .{},
    eval_only: bool = false,
    strict: bool = false,
    output: Output = .plain,
    add_root: ?[]const u8 = null,
    read_write: bool = false,
    readonly: bool = false,
    gc_warning: bool = true,
};

fn parse(k: *Cmd, argv: []const []const u8) Stop!Inst {
    const eql = std.mem.eql;
    var i: Inst = .{};
    var a: Argv = .{ .k = k, .all = argv };
    while (a.i < argv.len) : (a.i += 1) {
        const s = argv[a.i];
        if (eql(u8, s, "--eval") or eql(u8, s, "--eval-only")) {
            i.eval_only = true;
        } else if (eql(u8, s, "--read-write-mode")) {
            i.read_write = true;
        } else if (eql(u8, s, "--readonly-mode") or eql(u8, s, "--dry-run")) {
            i.readonly = true;
        } else if (eql(u8, s, "--strict")) {
            i.strict = true;
        } else if (eql(u8, s, "--json")) {
            i.output = .json;
        } else if (eql(u8, s, "--raw")) {
            i.output = .raw;
        } else if (eql(u8, s, "--add-root")) {
            // nix-instantiate.cc: an empty `gcRoot` is "no root", warning and all
            const v = try a.value("--add-root");
            i.add_root = if (v.len == 0) null else v;
        } else if (eql(u8, s, "--no-gc-warning")) {
            i.gc_warning = false;
        } else if (eql(u8, s, "-Q") or eql(u8, s, "--no-build-output")) {
            i.c.quiet = true;
        } else if (eql(u8, s, "--no-location")) {
            // it changes `--xml` output only, and `--xml` falls back
        } else if (eql(u8, s, "-")) {
            return k.fallBack("reading the expression from stdin is not implemented", .{});
        } else if (eql(u8, s, "--parse") or eql(u8, s, "--parse-only") or eql(u8, s, "--xml") or eql(u8, s, "--find-file")) {
            return k.fallBack("'{s}' is not implemented", .{s});
        } else if (!try classic.commonFlag(&i.c, &a, s)) {
            if (s.len > 0 and s[0] == '-') return k.fallBack("'{s}' is not implemented", .{s});
            try i.c.files.append(k.arena, s);
        }
    }
    if (i.eval_only and !i.read_write) i.readonly = true;
    if (i.c.files.items.len == 0 and !i.c.from_args) try i.c.files.append(k.arena, "./default.nix");
    if (i.c.flags.attrs.items.len == 0) try i.c.flags.attrs.append(k.arena, "");
    if (i.add_root != null and i.readonly) return k.fallBack("'--add-root' with a read-only store is not implemented", .{});
    return i;
}

pub fn main(c: *const cli.Ctx, argv: []const []const u8) u8 {
    var k: Cmd = .init(c, name, argv);
    return k.finish(body(&k));
}

fn body(k: *Cmd) Stop!u8 {
    var i = try parse(k, k.argv);
    // `nix-instantiate` builds nothing: the drvs, their sources and the
    // `--add-root` links belong to the local store whatever `builder` says.
    const st = try classic.settings(k, &i.c, false);
    const transport = try classic.local(k);
    if (!i.readonly and classic.storeGiven(&i.c) and !sameStore(&st.transport, &transport))
        return k.fallBack("'--store' is not the local daemon", .{});
    var ea = try classic.evalArgs(k, &i.c, st.cfg);
    const r = try classic.run(k, &i.c, st.cfg, &ea);
    var job: Job = .{ .k = k, .i = &i, .transport = &transport, .options = st.options };
    return classic.ran(k, r.go(&job, Job.go));
}

pub fn sameStore(x: *const Transport, y: *const Transport) bool {
    if (x.* != .unix or y.* != .unix) return false;
    return std.mem.eql(u8, x.unix, y.unix);
}

const Job = struct {
    k: *Cmd,
    i: *const Inst,
    transport: *const Transport,
    options: worker.Options,

    fn go(j: *Job, ev: *Evaluator) !u8 {
        const k = j.k;
        const i = j.i;
        const arena = k.arena;
        const dir = try classic.cwd(k);
        var roots: std.ArrayList(Root) = .empty;
        const args = try api.autoArgs(ev, arena, i.c.flags.args.items);
        const has_args = i.c.flags.args.items.len > 0;
        var warned = false;
        for (i.c.files.items) |file| {
            const root = try classic.evalInput(ev, arena, &i.c, file, dir);
            for (i.c.flags.attrs.items) |attr| {
                var v = try installable.findAlongAttrPath(ev, root, attr, args);
                if (i.eval_only) {
                    if (has_args) v = try ev.autoCall(v, args);
                    // nix-instantiate.cc writes each value as it has it, so
                    // what ran before a failing expression is on stdout already
                    var text: Writer.Allocating = .init(arena);
                    try printValue(ev, v, i, &text.writer);
                    classic.outLossy(k.s, text.written());
                } else {
                    // nix-instantiate.cc: one `getDerivations` per attribute
                    // path, so two of them that name one derivation give two roots
                    var seen: installable.Seen = .empty;
                    defer seen.deinit(ev.gpa);
                    try installable.getDrvsAt(ev, arena, v, args, &roots, &seen, attr);
                    if (!warned and roots.items.len > 0 and i.add_root == null and i.gc_warning) {
                        warned = true;
                        k.s.log.textLine(gc_warning);
                    }
                }
            }
        }
        if (i.eval_only) return 0;
        if (i.readonly or roots.items.len == 0) return j.finish(ev, roots.items, false);
        return j.finish(ev, roots.items, true);
    }

    /// Registers the closure, makes the `--add-root` links, prints the drv paths.
    fn finish(j: *Job, ev: *Evaluator, roots: []const Root, upload: bool) !u8 {
        const k = j.k;
        const s = k.s;
        const arena = k.arena;
        var d: Diag = .init(s.gpa);
        defer d.deinit();
        var prov: Provenance = .off(s.gpa);
        defer prov.deinit();
        var up: ?apibuild.Dispatch = null;
        defer if (up) |*x| x.deinit();
        if (upload) {
            var inputs: apibuild.EvalInputs = .init(ev);
            defer inputs.deinit();
            const paths = try arena.alloc(StorePath, roots.len);
            for (roots, paths) |r, *p| p.* = r.drv;
            const p = plan_mod.plan(s.gpa, s.io, paths, inputs.inputs(), &d) catch |e| return classic.report(s, &d, e);
            // no build, so nothing to render: the daemon's log lines go out as they are
            var style: apibuild.Style = .detect(&s.log);
            style.quiet = true;
            up = apibuild.Dispatch.open(s, k.c.init.environ_map, j.transport, j.options, p, &prov, style, &d) catch |e| return classic.report(s, &d, e);
            up.?.uploadOnly(paths[0..1], &d) catch |e| return classic.report(s, &d, e);
        }
        var out: std.ArrayList(u8) = .empty;
        var root_nr: usize = 0;
        for (roots) |r| {
            var shown: []const u8 = undefined;
            if (j.i.add_root != null and up != null) {
                root_nr += 1;
                var link = try classic.absPath(k, j.i.add_root.?);
                if (root_nr > 1) link = try std.fmt.allocPrint(arena, "{s}-{d}", .{ link, root_nr });
                const drv = try std.fmt.allocPrint(arena, "{f}", .{&r.drv});
                up.?.d.outLink(drv, link, &d) catch |e| return classic.report(s, &d, e);
                shown = link;
            } else shown = try std.fmt.allocPrint(arena, "{f}", .{&r.drv});
            if (std.mem.eql(u8, r.output, "out")) {
                try out.print(arena, "{s}\n", .{shown});
            } else try out.print(arena, "{s}!{s}\n", .{ shown, r.output });
        }
        classic.outLossy(s, out.items);
        return 0;
    }
};

fn printValue(ev: *Evaluator, v_in: Value, i: *const Inst, w: *Writer) Evaluator.Error!void {
    switch (i.output) {
        .raw => {
            var text: std.ArrayList(u8) = .empty;
            defer text.deinit(ev.gpa);
            var ctx: std.ArrayList(value.Ctx) = .empty;
            defer ctx.deinit(ev.gpa);
            try ev.coerceToString(v_in, &text, &ctx, .none, "while generating the nix-instantiate output", .{});
            w.writeAll(text.items) catch return error.OutOfMemory;
        },
        .json => {
            var ctx: std.ArrayList(value.Ctx) = .empty;
            defer ctx.deinit(ev.gpa);
            print.writeJson(ev, w, v_in, &ctx, i.strict, .none) catch |e| return print.inMemory(e);
            w.writeByte('\n') catch return error.OutOfMemory;
        },
        .plain => {
            const v = if (i.strict) try ev.forceDeep(v_in) else try ev.force(v_in);
            print.writeAmbiguous(ev, w, v) catch |e| return print.inMemory(e);
            w.writeByte('\n') catch return error.OutOfMemory;
        },
    }
}
