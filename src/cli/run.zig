//! `iets` as a function, for `main`: the session, `--iets-option`, the words that run before the settings
//! load (`version`, `help`, `__complete`), and the command word.

const std = @import("std");
const cli = @import("../cli.zig");
const help = @import("help.zig");
const complete = @import("complete.zig");
const Classic = cli.classic.Name;
const Session = @import("../session.zig").Session;
const Diag = @import("../diag.zig").Diag;
const Report = @import("../log.zig").Report;
const settings = @import("../settings.zig");
const errors = @import("../errors.zig");
const store_path = @import("../store/path.zig");
const sys = @import("../sys.zig");

/// `iets VERSION`, the version the build was given.
pub const version = "iets " ++ @import("build_options").version;

/// The classic name `argv0`'s base name is, if it is one.
pub fn classicName(argv0: []const u8) ?Classic {
    return Classic.fromWord(std.fs.path.basename(argv0));
}

/// The whole command line: the exit code.
pub fn main(init: *const std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const all = try init.minimal.args.toSlice(arena);
    const argv: []const []const u8 = if (all.len > 0) all[1..] else &.{};
    const classic = if (all.len > 0) classicName(all[0]) else null;

    // The session: the log, the settings, the events and the profile of this
    // run. Its log writes stderr unbuffered, a line at a time, as every thread
    // that reports goes through it.
    const s = try Session.create(init.gpa, init.io, .process(init.environ_map));
    defer s.destroy();
    var err_fd: sys.fs.FdWriter = .{ .fd = 2 };
    s.log.writeTo(&err_fd.interface);
    // no command until the command word is read
    s.log.command = null;
    // before the first store path is made: every hash takes it as input
    {
        const env = s.env;
        const set = env.nonEmpty("NIX_STORE_DIR") orelse env.nonEmpty("NIX_STORE");
        const r = store_path.resolveStoreDir(try arena.alloc(u8, 256), set, env.nonEmpty("PROGRAMDATA"), false);
        if (r.ignored) s.log.errln(try std.fmt.allocPrint(arena, "warning: ignoring NIX_STORE_DIR '{s}', it is not an absolute path", .{set.?}));
        store_path.store_dir = try arena.dupe(u8, r.dir);
    }
    return dispatch(s, init, argv, classic);
}

/// The command line after the session is made: `--iets-option`, the words
/// that run before the settings load, then the command word.
pub fn dispatch(s: *Session, init: *const std.process.Init, argv_in: []const []const u8, classic: ?Classic) !u8 {
    const arena = init.arena.allocator();
    var d: Diag = .init(init.gpa);
    defer d.deinit();
    // a classic fallback execs the real nix with what is left
    const taken = settings.takeOptions(arena, argv_in, &d) catch |e| switch (e) {
        error.Usage => {
            _ = fail(s, &d, e);
            return 2;
        },
        else => |x| return x,
    };
    const argv = taken.rest;
    // read before the first thing that can fail: it shapes an error's record
    for (argv, 0..) |a, k| if (std.mem.eql(u8, a, "--log-format")) {
        s.log.setFormat(if (k + 1 < argv.len) argv[k + 1] else "", &d) catch {};
        break;
    };
    s.log.showProgress();
    // these run before the settings file loads, so a broken file stays harmless
    if (classic == null and argv.len > 0) {
        const w = argv[0];
        if (std.mem.eql(u8, w, "--version") or std.mem.eql(u8, w, "version")) return help.out(s, version ++ "\n");
        if (isHelp(w) or std.mem.eql(u8, w, "help")) {
            s.log.command = "iets";
            return help.help(s, if (argv.len > 1) argv[1] else null);
        }
        // called on every tab, so a broken settings file would flood the shell
        if (std.mem.eql(u8, w, "__complete")) return complete.cmdComplete(&.{ .s = s, .init = init }, argv[1..]);
    }
    s.loadSettings(taken.options, &d) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(s, &d, e),
    };
    s.open();
    defer s.finish();
    return command(&.{ .s = s, .init = init }, argv, classic);
}

fn command(c: *const cli.Ctx, argv: []const []const u8, classic: ?Classic) !u8 {
    const s = c.s;
    if (classic) |name| return cli.classic.dispatch(c, name, argv);
    if (argv.len == 0) {
        s.log.err(help.overview);
        return 2;
    }
    if (Classic.fromWord(argv[0])) |name| return cli.classic.dispatch(c, name, argv[1..]);
    var rest = argv[1..];
    s.log.command = "iets";
    const word = argv[0];
    const cmd: cli.Command = if (std.mem.eql(u8, word, "cache-dump")) blk: {
        // `cache-dump FILE` is `cache dump FILE`
        const r = try c.init.arena.allocator().alloc([]const u8, rest.len + 1);
        r[0] = "dump";
        @memcpy(r[1..], rest);
        rest = r;
        break :blk .cache;
    } else cli.Command.fromWord(word) orelse {
        if (std.mem.startsWith(u8, word, "-")) return help.unknownFlag(s, word);
        return help.unknownCommand(s, word);
    };
    s.log.command = @tagName(cmd);
    switch (cmd) {
        // these read flags in order, so `--help` may be a flag's value
        .eval, .diff, .@"eval-jobs" => {},
        else => for (rest) |a| if (isHelp(a)) return help.help(s, @tagName(cmd)),
    }
    return cli.dispatch(c, cmd, rest);
}

fn isHelp(w: []const u8) bool {
    return std.mem.eql(u8, w, "--help") or std.mem.eql(u8, w, "-h");
}

/// An error outside the evaluator, reported with its code; the exit code.
fn fail(s: *Session, d: *const Diag, e: anyerror) u8 {
    return errors.report(e, d).emit(&s.log);
}

test classicName {
    try std.testing.expectEqual(.@"nix-build", classicName("/usr/bin/nix-build").?);
    try std.testing.expectEqual(null, classicName("iets"));
}
