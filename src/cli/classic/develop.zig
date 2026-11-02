//! `nix develop` (src/nix/develop.cc): the `print-dev-env` environment, then
//! bash. The rc script is `makeRcScript` plus the tail `CmdDevelop::run`
//! adds. See `docs/reference/classic.md`.
//!

const std = @import("std");
const errors = @import("../../errors.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = Io.Writer;
const linux = std.os.linux;
const Diag = @import("../../diag.zig").Diag;
const config = @import("../../config.zig");
const sys = @import("../../sys.zig");
const process = @import("../../sys/process.zig");
const devenv_mod = @import("../../devenv.zig");
const devenv = @import("../devenv.zig");
const hooks_mod = @import("../devenv_hooks.zig");
const classic = @import("mod.zig");
const nix = @import("nix.zig");
const Cmd = classic.Cmd;
const Stop = classic.Stop;
const Common = classic.Common;
const Argv = classic.Argv;

pub const Develop = struct {
    c: Common = .{},
    installable: ?[]const u8 = null,
    /// `-c`/`--command`: the command and its arguments, `exec`'d by the rc script.
    command: []const []const u8 = &.{},
    ignore_env: bool = false,
    keep: std.ArrayList([]const u8) = .empty,
    unset: std.ArrayList([]const u8) = .empty,
};

pub fn parse(k: *Cmd, argv: []const []const u8) Stop!Develop {
    const eql = std.mem.eql;
    var d: Develop = .{};
    var a: Argv = .{ .k = k, .all = argv };
    while (a.i < argv.len) : (a.i += 1) {
        const s = argv[a.i];
        if (eql(u8, s, "-c") or eql(u8, s, "--command")) {
            // develop.cc: the handler takes a vector, so `-c` eats the rest.
            d.command = argv[a.i + 1 ..];
            if (d.command.len == 0) return k.fallBack("--command requires at least one argument", .{});
            a.i = argv.len;
            break;
        } else if (eql(u8, s, "-i") or eql(u8, s, "--ignore-env") or eql(u8, s, "--ignore-environment")) {
            d.ignore_env = true;
        } else if (eql(u8, s, "-k") or eql(u8, s, "--keep") or eql(u8, s, "--keep-env-var")) {
            try d.keep.append(k.arena, try a.value(s));
        } else if (eql(u8, s, "-u") or eql(u8, s, "--unset") or eql(u8, s, "--unset-env-var")) {
            try d.unset.append(k.arena, try a.value(s));
        } else if (!try nix.globalFlag(&d.c, &a, s)) {
            if (s.len > 0 and s[0] == '-') return k.fallBack("'{s}' is not implemented", .{s});
            if (d.installable != null) return k.fallBack("'nix develop' takes one installable", .{});
            d.installable = s;
        }
    }
    if (d.ignore_env and d.unset.items.len > 0) return k.fallBack("--unset-env-var does not make sense with --ignore-env", .{});
    if (!d.ignore_env and d.keep.items.len > 0) return k.fallBack("--keep-env-var does not make sense without --ignore-env", .{});
    return d;
}

/// `nix develop [INSTALLABLE]`; `rest` is the arguments after the subcommand.
pub fn main(k: *Cmd, rest: []const []const u8) Stop!u8 {
    var d = try parse(k, rest);
    const st = try nix.nixSettings(k, &d.c, false, false);
    const installable = d.installable orelse ".";
    const dc: devenv.Ctx = .{ .s = k.s, .env_map = k.c.init.environ_map, .log = .of(&k.s.log) };
    var impl: hooks_mod.Impl = .{ .c = k.c };
    defer impl.deinit();
    const hooks = &impl;
    var diag: Diag = .init(k.s.gpa);
    defer diag.deinit();
    // the default evaluation flags with the `-I`s and `pure-eval`, on
    // classic mode's evaluator configuration
    impl.args = .{ .includes = d.c.flags.includes.items, .pure = d.c.flags.pure, .input = .{ .flake = installable } };
    const cls = try k.arena.create(@import("../../api.zig").run.Classic);
    cls.* = try classic.classicRun(k, &d.c, st.cfg, d.c.flags.pure.?);
    impl.classic = cls;
    // a hit reads the environment out of the local store, so only a local
    // daemon gets an entry
    if (st.transport == .unix) impl.openCache("develop");
    const root = try devenv.flakeShellRoot(&dc, k.arena, &st.transport, installable);
    const args: devenv.DevEnvArgs = .{ .transport = st.transport, .options = st.options, .gc_root = root };
    const env = devenv.devEnv(&dc, hooks, k.arena, installable, false, &args) catch return k.exit(hooks.code);
    return k.exit(exec(k, &d, st.cfg, &env) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => classic.report(k.s, &diag, e),
    });
}

/// Writes the rc file and execs bash. Returns only when something failed,
/// with the exit code of the error it reported.
fn exec(k: *Cmd, d: *const Develop, cfg: *const config.Config, dev: *const devenv.DevEnv) !u8 {
    const s = k.s;
    const arena = k.arena;
    var diag: Diag = .init(s.gpa);
    defer diag.deinit();
    // a private directory, so no other user can put a symlink where the rc
    // file and the attribute files go
    const dir = privateDir(k, &diag) catch |e| return classic.report(s, &diag, e);
    const attrs_dir = try std.fmt.allocPrint(arena, "{s}/attrs", .{dir});
    const outputs_dir = try std.fmt.allocPrint(arena, "{s}/outputs", .{try classic.cwd(k)});
    const rc_path = try std.fmt.allocPrint(arena, "{s}/rc", .{dir});
    const rc = devenv_mod.makeRcScript(s.gpa, arena, s.io, &dev.env, attrs_dir, outputs_dir, &diag) catch |e| return classic.report(s, &diag, e);
    defer s.gpa.free(rc.script);
    const store_bash = sys.fs.mode(dev.builder, true) != null and sys.fs.isFile(sys.fs.mode(dev.builder, true).?);
    const shell = if (store_bash) dev.builder else "bash";
    const script = try rcScript(arena, d, cfg, rc.script, rc_path, shell, store_bash);
    Io.Dir.cwd().writeFile(s.io, .{ .sub_path = rc_path, .data = script }) catch |e|
        return classic.report(s, &diag, failIo(&diag, e, "cannot write '{s}'", .{rc_path}));

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, "bash");
    if (d.command.len == 0) try argv.append(arena, "--rcfile");
    try argv.append(arena, rc_path);
    const envp = try environment(k, d, dev.out_path, shell);
    const e = process.execvpe(arena, shell, argv.items, envp, k.c.init.environ_map.get("PATH"));
    const r: @import("../../log.zig").Report = .{ .code = "io", .raw = try std.fmt.allocPrint(arena, "cannot execute '{s}': {f}", .{ shell, errors.osErrno(e) }) };
    return r.emit(&s.log);
}

fn failIo(d: *Diag, e: anyerror, comptime f: []const u8, a: anytype) anyerror {
    return d.fail(error.Io, f ++ ": {s}", a ++ .{@import("../../errors.zig").ioText(e)});
}

/// develop.cc:CmdDevelop::run's script: the rc file `makeRcScript` gave,
/// removing itself, and then the command, or the prompt settings.
pub fn rcScript(arena: Allocator, d: *const Develop, cfg: *const config.Config, base: []const u8, rc_path: []const u8, shell: []const u8, store_bash: bool) ![]const u8 {
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    if (d.command.len > 0) {
        try w.writeAll(base);
        try w.print("command rm -f '{s}'\n", .{rc_path});
        try w.writeAll("exec");
        for (d.command) |c| {
            try w.writeByte(' ');
            try devenv_mod.writeShellArgAlways(w, c);
        }
        try w.writeByte('\n');
    } else {
        try w.writeAll("[ -n \"$PS1\" ] && [ -e ~/.bashrc ] && source ~/.bashrc;\nshopt -u expand_aliases\n");
        try w.writeAll(base);
        try w.print("command rm -f '{s}'\n", .{rc_path});
        try w.writeAll("\nshopt -s expand_aliases\n");
        const forms = [_]struct { []const u8, []const u8, []const u8 }{
            .{ "bash-prompt", "PS1=", ";" },
            .{ "bash-prompt-prefix", "PS1=", "\"$PS1\";" },
            .{ "bash-prompt-suffix", "PS1+=", ";" },
        };
        for (forms) |f| {
            const v = cfg.str(f[0]) orelse continue;
            if (v.len == 0) continue;
            try w.print("[ -n \"$PS1\" ] && {s}", .{f[1]});
            try devenv_mod.writeShellArgAlways(w, v);
            try w.print("{s}\n", .{f[2]});
        }
    }
    // develop.cc takes bash from `nixpkgs#bashInteractive`; iets cannot
    // fetch, so the shell derivation's own builder is the bash
    // (docs/reference/classic.md).
    try w.print("SHELL=\"{s}\"\n", .{shell});
    if (store_bash) try w.print("PATH=\"{s}${{PATH:+:$PATH}}\"\n", .{std.fs.path.dirname(shell) orelse "/"});
    return out.written();
}

/// A fresh directory in `$TMPDIR` that only this user can enter, made with
/// exclusive creation so it is never something that was already there.
fn privateDir(k: *Cmd, d: *Diag) ![]const u8 {
    const tmp = sys.tempDir(k.s.env);
    for (0..16) |_| {
        const nanos: u64 = @intCast(@mod(Io.Clock.real.now(k.s.io).toNanoseconds(), std.time.ns_per_s));
        const dir = try std.fmt.allocPrintSentinel(k.arena, "{s}/iets-develop-{d}-{d}", .{ tmp, linux.getpid(), nanos }, 0);
        switch (linux.errno(linux.mkdir(dir, 0o700))) {
            .SUCCESS => return dir,
            .EXIST => continue,
            else => |e| return d.fail(error.Io, "cannot create '{s}': {f}", .{ dir, errors.osErrno(e) }),
        }
    }
    return d.fail(error.Usage, "cannot make a private directory in '{s}'", .{tmp});
}

/// command.cc:MixEnvironment::setEnviron, then develop.cc's `NIX_GCROOT`
/// and `SHELL`.
fn environment(k: *Cmd, d: *const Develop, gc_root: []const u8, shell: []const u8) ![*:null]const ?[*:0]const u8 {
    const arena = k.arena;
    var m: std.process.Environ.Map = .init(arena);
    var it = k.c.init.environ_map.iterator();
    while (it.next()) |e| {
        if (d.ignore_env) {
            for (d.keep.items) |n| {
                if (std.mem.eql(u8, n, e.key_ptr.*)) break;
            } else continue;
        }
        try m.put(e.key_ptr.*, e.value_ptr.*);
    }
    for (d.unset.items) |n| _ = m.swapRemove(n);
    try m.put("NIX_GCROOT", gc_root);
    try m.put("SHELL", shell);
    return (try m.createPosixBlock(arena, .{})).slice.ptr;
}

const testing = std.testing;

test "the rc tail runs the command or sets the prompt" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg: config.Config = .empty(a, testing.io, .{});
    try cfg.set("bash-prompt-suffix", "(dev) ");
    const cmd: Develop = .{ .command = &.{ "echo", "a b" } };
    try testing.expectEqualStrings(
        "BASE\ncommand rm -f '/t/rc'\nexec 'echo' 'a b'\nSHELL=\"/s/bin/bash\"\nPATH=\"/s/bin${PATH:+:$PATH}\"\n",
        try rcScript(a, &cmd, &cfg, "BASE\n", "/t/rc", "/s/bin/bash", true),
    );
    const sh: Develop = .{};
    try testing.expectEqualStrings(
        "[ -n \"$PS1\" ] && [ -e ~/.bashrc ] && source ~/.bashrc;\nshopt -u expand_aliases\nBASE\ncommand rm -f '/t/rc'\n\nshopt -s expand_aliases\n[ -n \"$PS1\" ] && PS1+='(dev) ';\nSHELL=\"bash\"\n",
        try rcScript(a, &sh, &cfg, "BASE\n", "/t/rc", "bash", false),
    );
}
