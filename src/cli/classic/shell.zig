//! `nix-shell` (src/nix/nix-build/nix-build.cc, the `runEnv` path): build
//! the derivation's *inputs*, then run bash on a rc file that sources
//! `$stdenv/setup` with the derivation's environment exported. This is not
//! `print-dev-env`; nothing here builds the `-env` derivation. See
//! `docs/reference/classic.md`.

const std = @import("std");
const text_ = @import("../../syntax/text.zig");
const errors = @import("../../errors.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = Io.Writer;
const linux = std.os.linux;
const Diag = @import("../../diag.zig").Diag;
const log = @import("../../log.zig");
const sys = @import("../../sys.zig");
const process = @import("../../sys/process.zig");
const Evaluator = @import("../../eval/Evaluator.zig");
const import_ = @import("../../eval/import.zig");
const value = @import("../../runtime/value.zig");
const Value = value.Value;
const remote = @import("../../remote.zig");
const worker = remote.worker;
const Transport = worker.Transport;
const event = remote.event;
const Event = event.Event;
const Sink = event.Sink;
const plan_mod = remote.plan;
const path_mod = @import("../../store/path.zig");
const StorePath = path_mod.StorePath;
const drv_mod = @import("../../store/drv.zig");
const Derivation = drv_mod.Derivation;
const locate = @import("../../store/locate.zig");
const SourceOrigin = @import("../../store/source.zig").SourceOrigin;
const api = @import("../../api.zig");
const installable = api.installable;
const Root = installable.Root;
const build = @import("../../build.zig");
const backend = build.backend;
const devenv_mod = @import("../../devenv.zig");
const devenv = @import("../devenv.zig");
const cli = @import("../../cli.zig");
const classic = @import("mod.zig");
const Cmd = classic.Cmd;
const Stop = classic.Stop;
const Common = classic.Common;
const Argv = classic.Argv;

const name = "nix-shell";

/// nix-build.cc: the environment variables `--pure` keeps, plus
/// `networkProxyVariables`. Nix means to keep the upper-case proxy
/// variables as well, but `getAllVariables` transforms into an empty
/// string, so only these lower-case names survive; iets keeps the same set.
const keep_vars = [_][]const u8{
    "HOME",                      "XDG_RUNTIME_DIR", "USER",      "LOGNAME",         "DISPLAY",
    "WAYLAND_DISPLAY",           "WAYLAND_SOCKET",  "PATH",      "TERM",            "IN_NIX_SHELL",
    "NIX_SHELL_PRESERVE_PROMPT", "TZ",              "PAGER",     "NIX_BUILD_SHELL", "SHLVL",
    "http_proxy",                "https_proxy",     "ftp_proxy", "all_proxy",       "no_proxy",
};

pub const Shell = struct {
    c: Common = .{},
    pure: bool = false,
    /// `--run`/`--command`, with the `exit` nix-build.cc appends.
    env_command: []const u8 = "",
    /// bash gets `--rcfile` only when it will be interactive.
    interactive: bool = false,
    /// `--keep NAME`, on top of `keep_vars`.
    keep: std.ArrayList([]const u8) = .empty,
};

/// `nix-shell`'s own flags: the tag is the word. The last of them are
/// Nix's and not implemented: they fall back.
const ShellFlag = enum {
    @"--run",
    @"--command",
    @"--pure",
    @"--impure",
    @"--keep",
    @"--add-drv-link",
    @"--indirect",
    @"--no-gc-warning",
    @"-Q",
    @"--no-build-output",
    @"-p",
    @"--packages",
    @"-i",
    @"-",
    @"--exclude",
    @"--dry-run",
    @"--check",
    @"--repair",
    @"-o",
    @"--out-link",
    @"--no-out-link",
    @"--no-link",
};

fn parse(k: *Cmd, argv: []const []const u8) Stop!Shell {
    // Same condition as bash uses for interactive shells.
    var s: Shell = .{ .interactive = sys.tty.isTerminal(0) and sys.tty.isTerminal(2) };
    var a: Argv = .{ .k = k, .all = argv };
    while (a.i < argv.len) : (a.i += 1) {
        const f = argv[a.i];
        const flag = std.meta.stringToEnum(ShellFlag, f) orelse {
            if (!try classic.commonFlag(&s.c, &a, f)) {
                if (f.len > 0 and f[0] == '-') return k.fallBack("'{s}' is not implemented", .{f});
                try s.c.files.append(k.arena, f);
            }
            continue;
        };
        switch (flag) {
            .@"--run", .@"--command" => {
                const v = try a.value(f);
                if (flag == .@"--run") s.interactive = false;
                s.env_command = try std.fmt.allocPrint(k.arena, "{s}\nexit", .{v});
            },
            .@"--pure" => s.pure = true,
            .@"--impure" => s.pure = false,
            .@"--keep" => try s.keep.append(k.arena, try a.value(f)),
            // no-ops in Nix too: nix-build.cc calls the first two obsolete,
            // and only nix-instantiate has a GC warning
            .@"--add-drv-link", .@"--indirect", .@"--no-gc-warning" => {},
            .@"-Q", .@"--no-build-output" => s.c.quiet = true,
            .@"-p", .@"--packages", .@"-i", .@"-", .@"--exclude", .@"--dry-run", .@"--check", .@"--repair", .@"-o", .@"--out-link", .@"--no-out-link", .@"--no-link" => return k.fallBack("'{s}' is not implemented", .{f}),
        }
    }
    if (s.c.flags.attrs.items.len == 0) try s.c.flags.attrs.append(k.arena, "");
    return s;
}

/// nix-build.cc reads `argv[1]` and treats it as a `#!` script when it
/// starts with `#!`; that whole mode (`-i INTERPRETER`) belongs to the real
/// nix-shell.
fn isShebang(k: *Cmd, argv: []const []const u8) bool {
    if (argv.len == 0) return false;
    var buf: [2]u8 = undefined;
    const f = Io.Dir.cwd().openFile(k.s.io, argv[0], .{}) catch return false;
    defer f.close(k.s.io);
    const n = f.readPositionalAll(k.s.io, &buf, 0) catch return false;
    return n == 2 and buf[0] == '#' and buf[1] == '!';
}

pub fn main(c: *const cli.Ctx, argv: []const []const u8) u8 {
    var k: Cmd = .init(c, name, argv);
    return k.finish(body(&k));
}

fn body(k: *Cmd) Stop!u8 {
    if (isShebang(k, k.argv)) return k.fallBack("a '#!' script", .{});
    var s = try parse(k, k.argv);
    if (!try defaultFile(k, &s)) {
        const r: log.Report = .{ .code = "usage", .raw = "no argument specified and no 'shell.nix' or 'default.nix' file found in the working directory" };
        return k.exit(r.emit(&k.s.log));
    }
    const st = try classic.settings(k, &s.c, false);
    var d: Diag = .init(k.arena);
    if ((st.cfg.boolean("nix-shell-always-looks-for-shell-nix", &d) catch null) == false)
        return k.fallBack("'nix-shell-always-looks-for-shell-nix = false' is not implemented", .{});
    // nix-build.cc sets this before it evaluates, so `builtins.getEnv` sees
    // it and the child inherits it.
    const in_shell = if (s.pure) "pure" else "impure";
    _ = setenv("IN_NIX_SHELL", in_shell, 1);
    try k.c.init.environ_map.put("IN_NIX_SHELL", in_shell);
    const cores = st.cfg.cores(&d) catch |e| return k.fail(&d, e);
    var ea = try classic.evalArgs(k, &s.c, st.cfg);
    const r = try classic.run(k, &s.c, st.cfg, &ea);
    var job: Job = .{ .k = k, .s = &s, .transport = &st.transport, .options = st.options, .cores = cores };
    const code = try classic.ran(k, r.go(&job, Job.go));
    const x = job.exec orelse return code;
    const e = process.execvpe(k.arena, x.shell, x.argv, x.envp, x.path);
    const rep: log.Report = .{ .code = "io", .raw = try std.fmt.allocPrint(k.arena, "executing shell '{s}': {f}", .{ x.shell, errors.osErrno(e) }) };
    return rep.emit(&k.s.log);
}

/// nix-build.cc: with no file argument, `shell.nix` then `default.nix`, and
/// a clearer error than the evaluator's when neither is there. False: none.
fn defaultFile(k: *Cmd, s: *Shell) Stop!bool {
    if (s.c.from_args or s.c.files.items.len > 0) return true;
    if (!sys.fs.exists("shell.nix") and !sys.fs.exists("default.nix")) return false;
    try s.c.files.append(k.arena, ".");
    return true;
}

/// nix-build.cc:resolveShellExprPath: a directory resolves to `shell.nix`,
/// not to `default.nix`, when it has one.
fn resolveShellExprPath(ev: *Evaluator, a: Allocator, p: []const u8) Evaluator.Error![]const u8 {
    const m = sys.fs.mode(p, true) orelse return p;
    if (!sys.fs.isDir(m)) return p;
    for ([_][]const u8{ "shell.nix", "default.nix" }) |n| {
        const c = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ p, if (std.mem.endsWith(u8, p, "/")) "" else "/", n });
        if (sys.fs.exists(c)) return c;
    }
    return ev.fail(.eval, .none, "neither 'shell.nix' nor 'default.nix' found in '{s}'", .{p});
}

/// What exec runs once the evaluator is gone.
const Exec = struct {
    shell: []const u8,
    argv: []const []const u8,
    envp: [*:null]const ?[*:0]const u8,
    /// The child's `PATH`, where a bare `bash` is looked up.
    path: ?[]const u8,
};

const Bash = union(enum) {
    /// `$NIX_BUILD_SHELL`, or `bash` from `PATH` when nixpkgs has no
    /// `bashInteractive` to evaluate.
    path: []const u8,
    /// `(import <nixpkgs> {}).bashInteractive`, still to be built.
    drv: StorePath,
};

const Job = struct {
    k: *Cmd,
    s: *const Shell,
    transport: *const Transport,
    options: worker.Options,
    cores: u64,
    exec: ?Exec = null,

    /// Evaluates the shell derivation and bash, uploads the closure, builds
    /// the derivation's inputs, and prepares the exec.
    fn go(j: *Job, ev: *Evaluator) !u8 {
        const k = j.k;
        const s = j.s;
        const arena = k.arena;
        const dir = try classic.cwd(k);
        var roots: std.ArrayList(Root) = .empty;
        const args0 = try api.autoArgs(ev, arena, s.c.flags.args.items);
        var seen: installable.Seen = .empty;
        defer seen.deinit(ev.gpa);
        // What the user asked for, resolved: the files (or expressions) and
        // the attribute paths. It names this project's roots (`keepInputs`).
        var key: std.ArrayList([]const u8) = .empty;
        try key.append(arena, "nix-shell");
        for (s.c.files.items) |file| {
            var root: Value = undefined;
            if (s.c.from_args) {
                try key.append(arena, file);
                root = try import_.evalString(ev, file);
            } else {
                const p0 = try classic.lookupFileArg(ev, arena, file, dir);
                const p = try resolveShellExprPath(ev, arena, p0);
                try key.append(arena, p);
                root = try import_.evalFile(ev, p, .none);
            }
            root = try ev.force(root);
            const args = if (takesInNixShell(ev, root)) try withInNixShell(ev, args0) else args0;
            for (s.c.flags.attrs.items) |attr| {
                var v = try installable.findAlongAttrPath(ev, root, attr, args);
                v = try ev.force(v);
                const args2 = if (takesInNixShell(ev, v)) try withInNixShell(ev, args) else args;
                try installable.getDrvsAt(ev, arena, v, args2, &roots, &seen, attr);
            }
        }
        const bash = try j.findBash(ev);
        if (roots.items.len != 1) {
            const r: log.Report = .{ .code = "usage", .raw = "nix-shell requires a single derivation" };
            return r.emit(&k.s.log);
        }
        const drv_path = roots.items[0].drv;
        var d: Diag = .init(k.s.gpa);
        defer d.deinit();
        const drv = loadDrv(ev, arena, drv_path, &d) catch |e| return classic.report(k.s, &d, e);
        for (drv.outputs) |o| if (o.output != .input_addressed)
            return classic.unsupported(ev, "the derivation '{f}' has to be resolved first", .{&drv_path});
        var targets: std.ArrayList(StorePath) = .empty;
        try targets.append(arena, drv_path);
        if (bash == .drv) try targets.append(arena, bash.drv);
        try key.appendSlice(arena, s.c.flags.attrs.items);
        var inputs: api.build.EvalInputs = .init(ev);
        defer inputs.deinit();
        var p = plan_mod.plan(k.s.gpa, k.s.io, targets.items, inputs.inputs(), &d) catch |e| return classic.report(k.s, &d, e);
        defer p.deinit();
        return j.realise(&drv_path, &drv, bash, &p, key.items);
    }

    /// nix-build.cc: `$NIX_BUILD_SHELL`, else `(import <nixpkgs>
    /// {}).bashInteractive`; any evaluation error means bash from the
    /// environment.
    fn findBash(j: *Job, ev: *Evaluator) Evaluator.Error!Bash {
        const k = j.k;
        if (k.c.init.environ_map.get("NIX_BUILD_SHELL")) |sh| return .{ .path = sh };
        var roots: std.ArrayList(Root) = .empty;
        const r = blk: {
            const v = import_.evalString(ev, "(import <nixpkgs> {}).bashInteractive") catch |e| break :blk e;
            const empty = (ev.mkAttrs(&.{}, .none) catch |e| break :blk e).as(value.Attrs);
            var seen: installable.Seen = .empty;
            defer seen.deinit(ev.gpa);
            installable.getDrvs(ev, k.arena, v, empty, &roots, &seen) catch |e| break :blk e;
        };
        r catch |e| {
            if (e != error.EvalFailed) return e;
            _ = api.report(ev, k.s, k.arena) catch {};
            ev.clearFailure();
            k.s.log.textLine("uses bash from your environment");
            return .{ .path = "bash" };
        };
        if (roots.items.len == 1) return .{ .drv = roots.items[0].drv };
        const rep: log.Report = .{ .code = "type", .raw = "the 'bashInteractive' attribute in <nixpkgs> did not evaluate to a derivation" };
        _ = rep.emit(&k.s.log);
        k.s.log.textLine("uses bash from your environment");
        return .{ .path = "bash" };
    }

    /// Uploads the closure, builds the derivation's inputs (and bash) and
    /// prepares the exec; the exit code of a failure.
    fn realise(j: *Job, drv_path: *const StorePath, drv: *const Derivation, bash: Bash, p: *plan_mod.Plan, key: []const []const u8) !u8 {
        const k = j.k;
        const s = k.s;
        const arena = k.arena;
        var d: Diag = .init(s.gpa);
        defer d.deinit();
        var sink: EventSink = .{ .s = s, .quiet = j.s.c.quiet };
        const on_event = Sink.of(EventSink, &sink);
        const cx: backend.Context = .{ .gpa = s.gpa, .io = s.io, .env = k.c.init.environ_map, .log = .of(&s.log) };
        const w = backend.Worker.open(cx, j.transport, j.options, on_event, &d) catch |e| return classic.report(s, &d, e);
        defer w.close();
        // nix-shell realises the derivation's inputs, never the derivation itself.
        var wanted: std.ArrayList([]const u8) = .empty;
        for (drv.input_drvs) |in| {
            if (in.node.outputs.len == 0) continue;
            const outs = try std.mem.join(arena, ",", in.node.outputs);
            try wanted.append(arena, try std.fmt.allocPrint(arena, "{f}!{s}", .{ &in.path, outs }));
        }
        for (drv.input_srcs) |*src| try wanted.append(arena, try std.fmt.allocPrint(arena, "{f}", .{src}));
        if (bash == .drv) try wanted.append(arena, try std.fmt.allocPrint(arena, "{f}!out", .{&bash.drv}));
        const Loc = struct {
            nix: locate.Nix,
            fn f(c: ?*anyopaque, paths: []const StorePath, out: []?SourceOrigin, a: Allocator, dd: *Diag) anyerror!void {
                const l: *@This() = @ptrCast(@alignCast(c.?));
                const none: locate.Overrides = .empty;
                return locate.locateInStore(a, l.nix, paths, &none, out, dd);
            }
        };
        var loc: Loc = .{ .nix = .{ .io = s.io, .env = s.env, .nix_bin_dir = s.settings.nix_bin_dir } };
        var up: build.upload.PlanUpload = .init(s.gpa, s.io, p, .{ .ctx = &loc, .f = Loc.f });
        defer up.deinit();
        _ = up.upload(backend.Backend.of(backend.Worker, w), &.{drv_path.*}, on_event, &d) catch |e| return classic.report(s, &d, e);
        const results = w.conn.buildPathsWithResults(arena, wanted.items, on_event, &d) catch |e| return classic.report(s, &d, e);
        for (results) |b| {
            if (b.success()) continue;
            const code = log.buildExit(b.status, b.msg);
            sink.failed = true;
            const reason = try std.fmt.allocPrint(arena, "status {d}: {s}", .{ b.status, b.msg });
            const text = try std.fmt.allocPrint(arena, "error: build failed: {s}", .{reason});
            s.log.buildFailed(null, reason, code, text);
        }
        if (sink.failed) return 1;
        const shell = switch (bash) {
            .path => |x| x,
            .drv => |bp| blk: {
                const m = w.conn.queryDerivationOutputMap(arena, try std.fmt.allocPrint(arena, "{f}", .{&bp}), on_event, &d) catch |e| return classic.report(s, &d, e);
                for (m) |o| if (std.mem.eql(u8, o.name, "out")) if (o.path) |op| break :blk try std.fmt.allocPrint(arena, "{s}/bin/bash", .{op});
                return classic.report(s, &d, d.fail(error.Store, "derivation '{f}' has no output 'out'", .{&bp}));
            },
        };
        j.keepInputs(w, drv, bash, shell, key, on_event);
        j.exec = j.prepareExec(drv, shell, &d) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => return classic.report(s, &d, e),
        };
        return 0;
    }

    /// Keeps what this entry realised alive, so that the next entry rebuilds
    /// nothing. `nix-shell` builds the derivation's inputs and not the
    /// derivation, and no store path holds them all, so iets's roots store
    /// gets one link each. The links are keyed on what the user asked for and
    /// the path's place in the sorted list: a project replaces its own set in
    /// place, and the TTL sweep takes what a set that shrank leaves. Best
    /// effort and silent, as `devenv.keepRoot`.
    fn keepInputs(j: *Job, w: *backend.Worker, drv: *const Derivation, bash: Bash, shell: []const u8, key: []const []const u8, on_event: Sink) void {
        const k = j.k;
        const dc: devenv.Ctx = .{ .s = k.s, .env_map = k.c.init.environ_map, .log = .of(&k.s.log) };
        if (!devenv.shellRoots(&dc, j.transport)) return;
        const arena = k.arena;
        var paths: std.ArrayList([]const u8) = .empty;
        for (drv.input_srcs) |*src| paths.append(arena, std.fmt.allocPrint(arena, "{f}", .{src}) catch return) catch return;
        var d: Diag = .init(arena);
        for (drv.input_drvs) |in| {
            if (in.node.outputs.len == 0) continue;
            const full = std.fmt.allocPrint(arena, "{f}", .{&in.path}) catch return;
            const m = w.conn.queryDerivationOutputMap(arena, full, on_event, &d) catch return;
            for (in.node.outputs) |o| for (m) |e| if (std.mem.eql(u8, e.name, o)) if (e.path) |p| paths.append(arena, p) catch return;
        }
        // `shell` is `<output>/bin/bash` when nixpkgs built the bash
        if (bash == .drv) if (std.fs.path.dirname(shell)) |bin| if (std.fs.path.dirname(bin)) |out| paths.append(arena, out) catch return;
        std.mem.sort([]const u8, paths.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        var n: usize = 0;
        for (paths.items) |p| {
            if (n > 0 and std.mem.eql(u8, paths.items[n - 1], p)) continue;
            paths.items[n] = p;
            n += 1;
        }
        const parts = arena.alloc([]const u8, key.len + 1) catch return;
        @memcpy(parts[0..key.len], key);
        for (paths.items[0..n], 0..) |p, i| {
            parts[key.len] = std.fmt.allocPrint(arena, "{d}", .{i}) catch return;
            const link = (devenv.rootLink(arena, k.c.init.environ_map, parts) catch return) orelse return;
            devenv.keepRoot(&dc, j.transport, link, p, w.conn);
        }
    }

    /// nix-build.cc's `runEnv` tail: the environment, the rc file, the
    /// arguments of `execvp`.
    fn prepareExec(j: *Job, drv: *const Derivation, shell: []const u8, d: *Diag) !Exec {
        const k = j.k;
        const s = j.s;
        const arena = k.arena;
        const io = k.s.io;
        const nanos: u64 = @intCast(@mod(Io.Clock.real.now(io).toNanoseconds(), std.time.ns_per_s));
        const tmp = try std.fmt.allocPrint(arena, "{s}/nix-shell-{d}-{d}", .{ sys.tempDir(k.s.env), linux.getpid(), nanos });
        Io.Dir.cwd().createDirPath(io, tmp) catch |e| return failIo(d, e, "cannot create '{s}'", .{tmp});

        var env: std.process.Environ.Map = .init(arena);
        var it = k.c.init.environ_map.iterator();
        while (it.next()) |e| {
            if (s.pure and !kept(s, e.key_ptr.*)) continue;
            try env.put(e.key_ptr.*, e.value_ptr.*);
        }
        // NixOS hack: prevent /etc/bashrc from sourcing /etc/profile.
        if (s.pure) try env.put("__ETC_PROFILE_SOURCED", "1");
        for ([_][]const u8{ "NIX_BUILD_TOP", "TMPDIR", "TEMPDIR", "TMP", "TEMP" }) |v| try env.put(v, tmp);
        try env.put("NIX_STORE", path_mod.store_dir);
        const cores = if (j.cores == 0) std.Thread.getCpuCount() catch 1 else j.cores;
        try env.put("NIX_BUILD_CORES", try std.fmt.allocPrint(arena, "{d}", .{cores}));

        var pass_as_file: std.ArrayList([]const u8) = .empty;
        if (drv.structured_attrs == null) {
            var words = std.mem.tokenizeAny(u8, drv.envGet("passAsFile") orelse "", " \t\n\r");
            while (words.next()) |x| try pass_as_file.append(arena, x);
        }
        var file_nr: usize = 0;
        for (drv.env.items) |e| {
            const as_file = for (pass_as_file.items) |x| {
                if (std.mem.eql(u8, x, e.key)) break true;
            } else false;
            if (as_file) {
                const p = try std.fmt.allocPrint(arena, "{s}/.attr-{d}", .{ tmp, file_nr });
                file_nr += 1;
                try write(io, p, e.value, d);
                try env.put(try std.fmt.allocPrint(arena, "{s}Path", .{e.key}), p);
            } else try env.put(e.key, e.value);
        }

        var structured_rc: []const u8 = "";
        if (drv.structured_attrs) |sa| {
            var json = try prepareStructuredAttrs(arena, sa, drv.outputs, d);
            structured_rc = try writeShell(arena, &json);
            const sh = try std.fmt.allocPrint(arena, "{s}/.attrs.sh", .{tmp});
            const js = try std.fmt.allocPrint(arena, "{s}/.attrs.json", .{tmp});
            var text: Writer.Allocating = .init(arena);
            log.writeValue(&text.writer, arena, .{ .object = json }) catch return error.OutOfMemory;
            try write(io, js, text.written(), d);
            try write(io, sh, structured_rc, d);
            try env.put("NIX_ATTRS_SH_FILE", sh);
            try env.put("NIX_ATTRS_JSON_FILE", js);
        }

        const rc_path = try std.fmt.allocPrint(arena, "{s}/rc", .{tmp});
        const tz = k.c.init.environ_map.get("TZ");
        try write(io, rc_path, try rcScript(arena, s, shell, tmp, structured_rc, tz, sys.tty.isRoot()), d);

        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(arena, "bash");
        if (s.interactive) try argv.append(arena, "--rcfile");
        try argv.append(arena, rc_path);
        return .{
            .shell = shell,
            .argv = argv.items,
            .envp = (try env.createPosixBlock(arena, .{})).slice.ptr,
            .path = env.get("PATH"),
        };
    }
};

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

fn kept(s: *const Shell, k: []const u8) bool {
    for (keep_vars) |v| if (std.mem.eql(u8, v, k)) return true;
    for (s.keep.items) |v| if (std.mem.eql(u8, v, k)) return true;
    return false;
}

fn failIo(d: *Diag, e: anyerror, comptime f: []const u8, a: anytype) anyerror {
    if (e == error.OutOfMemory) return e;
    return d.fail(error.Io, f ++ ": {s}", a ++ .{@import("../../errors.zig").ioText(e)});
}

fn write(io: Io, path: []const u8, text: []const u8, d: *Diag) !void {
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }) catch |e| return failIo(d, e, "cannot write '{s}'", .{path});
}

/// The daemon's events while the inputs build: log lines as they come,
/// unless `-Q`; a failure as Nix's line.
const EventSink = struct {
    s: *@import("../../session.zig").Session,
    quiet: bool,
    failed: bool = false,

    pub fn onEvent(x: *EventSink, e: Event) void {
        switch (e) {
            // under internal-json a line of a build is already its result record
            .log => |l| if (!x.quiet and (l.drv_path.len == 0 or !x.s.log.isJson())) {
                var buf: Writer.Allocating = .init(x.s.gpa);
                defer buf.deinit();
                writeLossy(&buf.writer, l.line) catch return;
                x.s.log.textLine(buf.written());
            },
            .failed => |f| {
                x.failed = true;
                const text = std.fmt.allocPrint(x.s.gpa, "error: build of '{s}' failed: {s}", .{ f.drv_path, f.reason }) catch return;
                defer x.s.gpa.free(text);
                x.s.log.textLine(text);
            },
            else => {},
        }
    }
};

/// `String::from_utf8_lossy`: an invalid sequence is one U+FFFD.
fn writeLossy(w: *Writer, b: []const u8) Writer.Error!void {
    var i: usize = 0;
    while (i < b.len) {
        const n = std.unicode.utf8ByteSequenceLength(b[i]) catch {
            try w.writeAll("\u{fffd}");
            i += 1;
            continue;
        };
        if (i + n <= b.len and std.unicode.utf8ValidateSlice(b[i .. i + n])) {
            try w.writeAll(b[i .. i + n]);
            i += n;
        } else {
            try w.writeAll("\u{fffd}");
            i += text_.invalidLen(b, i);
        }
    }
}

/// The shell derivation as this evaluation wrote it, else from the store.
fn loadDrv(ev: *Evaluator, arena: Allocator, path: StorePath, d: *Diag) !Derivation {
    const aterm = blk: {
        ev.shared.drv_lock.lock(ev);
        defer ev.shared.drv_lock.unlock(ev);
        const i = ev.shared.drv.table.get(path.baseName()) orelse break :blk null;
        break :blk i.aterm;
    };
    if (aterm) |t| return Derivation.parse(arena, t, try Derivation.nameFromPath(&path, d), d);
    return drv_mod.loadDerivationFromStore(ev.io, arena, path, d);
}

/// nix-build.cc:takesNixShellAttr: a function with an `inNixShell` formal
/// gets it passed as `true`.
fn takesInNixShell(ev: *Evaluator, v: Value) bool {
    if (v.isThunk()) return false;
    return switch (v.view()) {
        .lambda => |l| switch (l.lam.param) {
            .ident => false,
            .formals => |p| for (p.formals) |f| {
                if (std.mem.eql(u8, ev.interner.name(f.sym), "inNixShell")) break true;
            } else false,
        },
        else => false,
    };
}

fn withInNixShell(ev: *Evaluator, args: *value.Attrs) Evaluator.Error!*value.Attrs {
    var entries: std.ArrayList(value.Attr) = .empty;
    defer entries.deinit(ev.gpa);
    try entries.appendSlice(ev.gpa, args.attrs());
    try entries.append(ev.gpa, .{ .sym = try ev.sym("inNixShell"), .pos = .none, .cell = .init(.true) });
    return (try ev.mkAttrs(entries.items, .none)).as(value.Attrs);
}

/// nix-build.cc's rc file, piece for piece.
pub fn rcScript(a: Allocator, s: *const Shell, shell: []const u8, tmp: []const u8, structured_rc: []const u8, tz: ?[]const u8, root: bool) ![]const u8 {
    const esc = devenv_mod.writeShellArgAlways;
    const bin = std.fs.path.dirname(shell) orelse if (std.mem.startsWith(u8, shell, "/")) "/" else "";
    var out: Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.writeAll("_nix_shell_clean_tmpdir() { command rm -rf ");
    try esc(w, tmp);
    try w.writeAll("; };");
    try w.writeAll("trap _nix_shell_clean_tmpdir EXIT; ");
    try w.writeAll("exitHooks+=(_nix_shell_clean_tmpdir); ");
    try w.writeAll("failureHooks+=(_nix_shell_clean_tmpdir); ");
    if (!s.pure) {
        try w.writeAll("[ -n \"$PS1\" ] && [ -e ~/.bashrc ] && source ~/.bashrc;");
        try w.writeAll("p=$PATH; ");
    }
    // Always clear PATH; an impure shell rehydrates it from $p below.
    try w.writeAll("unset PATH;");
    try w.writeAll("dontAddDisableDepTrack=1;\n");
    try w.writeAll(structured_rc);
    try w.writeAll("\n[ -e $stdenv/setup ] && source $stdenv/setup; ");
    if (!s.pure) try w.writeAll("PATH=$PATH:$p; unset p; ");
    try w.writeAll("PATH=");
    try esc(w, bin);
    try w.writeAll(":\"$PATH\"; ");
    try w.writeAll("SHELL=");
    try esc(w, shell);
    try w.writeAll("; ");
    try w.writeAll("BASH=");
    try esc(w, shell);
    try w.writeAll("; ");
    try w.writeAll("set +e; ");
    try w.writeAll("[ -n \"$PS1\" -a -z \"$NIX_SHELL_PRESERVE_PROMPT\" ] && ");
    try w.print("PS1='\\n\\[\\033[{s}m\\][nix-shell:\\w]\\$\\[\\033[0m\\] '; ", .{if (root) "1;31" else "1;32"});
    try w.writeAll("if [ \"$(type -t runHook)\" = function ]; then runHook shellHook; fi; ");
    try w.writeAll("unset NIX_ENFORCE_PURITY; ");
    try w.writeAll("shopt -u nullglob; ");
    try w.writeAll("unset TZ; ");
    if (tz) |t| {
        try w.writeAll("export TZ=");
        try esc(w, t);
        try w.writeAll("; ");
    }
    try w.writeAll("shopt -s execfail;");
    try w.writeAll(s.env_command);
    return out.written();
}

/// parsed-derivations.cc:StructuredAttrs::prepareStructuredAttrs. `outputs`
/// becomes the output placeholders; `exportReferencesGraph` would need path
/// info and closures, so it falls back to the real nix-shell.
pub fn prepareStructuredAttrs(a: Allocator, sa: []const u8, outputs: []const drv_mod.NamedOutput, d: *Diag) !std.json.ObjectMap {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, sa, .{ .parse_numbers = false }) catch |e|
        return d.fail(error.Store, "structured attrs are not valid JSON: {s}", .{@errorName(e)});
    if (parsed != .object) return d.fail(error.Store, "structured attrs are not valid JSON: not an object", .{});
    var json = parsed.object;
    const exports = if (json.get("exportReferencesGraph")) |x| switch (x) {
        .null => false,
        .object => |o| o.count() > 0,
        else => true,
    } else false;
    if (exports) return d.fail(error.Usage, "'exportReferencesGraph' in a nix-shell derivation is not implemented", .{});
    var outs: std.json.ObjectMap = .empty;
    for (outputs) |o| {
        const ph = path_mod.hashPlaceholder(o.name);
        try outs.put(a, o.name, .{ .string = try a.dupe(u8, &ph) });
    }
    try json.put(a, "outputs", .{ .object = outs });
    return json;
}

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn sortedKeys(a: Allocator, o: *const std.json.ObjectMap) ![]const []const u8 {
    const keys = try a.dupe([]const u8, o.keys());
    std.mem.sort([]const u8, keys, {}, lessStr);
    return keys;
}

/// parsed-derivations.cc:StructuredAttrs::writeShell: the `declare` lines
/// for every attribute whose value bash can hold.
pub fn writeShell(a: Allocator, json: *const std.json.ObjectMap) ![]const u8 {
    var out: Writer.Allocating = .init(a);
    const w = &out.writer;
    for (try sortedKeys(a, json)) |key| {
        if (!isShVarName(key)) continue;
        const v = json.get(key).?;
        if (try simpleType(a, v)) |s| {
            try w.print("declare {s}={s}\n", .{ key, s });
        } else switch (v) {
            .array => |arr| {
                var s2: std.ArrayList(u8) = .empty;
                const all = for (arr.items) |x| {
                    const s = (try simpleType(a, x)) orelse break false;
                    try s2.appendSlice(a, s);
                    try s2.append(a, ' ');
                } else true;
                if (all) try w.print("declare -a {s}=({s})\n", .{ key, s2.items });
            },
            .object => |o| {
                var s2: Writer.Allocating = .init(a);
                const all = for (try sortedKeys(a, &o)) |k2| {
                    const s = (try simpleType(a, o.get(k2).?)) orelse break false;
                    try s2.writer.writeByte('[');
                    try devenv_mod.writeShellArgAlways(&s2.writer, k2);
                    try s2.writer.print("]={s} ", .{s});
                } else true;
                if (all) try w.print("declare -A {s}=({s})\n", .{ key, s2.written() });
            },
            else => {},
        }
    }
    return out.written();
}

/// parsed-derivations.cc:shVarName, `[A-Za-z_][A-Za-z0-9_]*` matched whole.
pub fn isShVarName(s: []const u8) bool {
    if (s.len == 0 or !(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    for (s[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

/// `handleSimpleType`: a string, an integral number, `null` or a bool.
fn simpleType(a: Allocator, v: std.json.Value) !?[]const u8 {
    return switch (v) {
        .string => |s| try devenv_mod.escapeShellArgAlways(a, s),
        .number_string => |n| blk: {
            const x = std.fmt.parseFloat(f64, n) catch break :blk null;
            const f: f32 = @floatCast(x);
            if (@ceil(f) != f) break :blk null;
            // saturated, NaN to 0, as Rust iets's `as i32` does
            const i: i32 = if (std.math.isNan(x)) 0 else if (x >= 2147483647.0) std.math.maxInt(i32) else if (x <= -2147483648.0) std.math.minInt(i32) else @intFromFloat(x);
            break :blk try std.fmt.allocPrint(a, "{d}", .{i});
        },
        .integer => |n| try std.fmt.allocPrint(a, "{d}", .{n}),
        .float => |x| if (@ceil(@as(f32, @floatCast(x))) == @as(f32, @floatCast(x))) try std.fmt.allocPrint(a, "{d}", .{@as(i32, @intFromFloat(x))}) else null,
        .null => "''",
        .bool => |b| if (b) "1" else "",
        else => null,
    };
}

const testing = std.testing;

test "sh var names" {
    try testing.expect(isShVarName("a_B9"));
    try testing.expect(isShVarName("_"));
    try testing.expect(!isShVarName("9a"));
    try testing.expect(!isShVarName("a-b"));
    try testing.expect(!isShVarName(""));
}

test "declares for every bash-shaped value" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"name":"x","doCheck":true,"off":false,"n":3,"f":1.5,"nil":null,
        \\ "l":["a","b"],"bad":[{"x":1}],"m":{"k":"v"},"not a name":1,
        \\ "deep":{"k":[1]}}
    , .{ .parse_numbers = false });
    try testing.expectEqualStrings(
        "declare doCheck=1\n" ++
            "declare -a l=('a' 'b' )\n" ++
            "declare -A m=(['k']='v' )\n" ++
            "declare n=3\n" ++
            "declare name='x'\n" ++
            "declare nil=''\n" ++
            "declare off=\n",
        try writeShell(a, &v.object),
    );
}

test "outputs become placeholders" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .init(a);
    const outputs = [_]drv_mod.NamedOutput{.{ .name = "out", .output = .deferred }};
    const json = try prepareStructuredAttrs(a, "{\"name\":\"x\"}", &outputs, &d);
    const ph = path_mod.hashPlaceholder("out");
    try testing.expectEqualStrings(&ph, json.get("outputs").?.object.get("out").?.string);
    try testing.expectError(error.Usage, prepareStructuredAttrs(a, "{\"exportReferencesGraph\":{\"a\":[\"/nix/store/x\"]}}", &outputs, &d));
}
