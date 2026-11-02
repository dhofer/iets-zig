//! The argument parsing the evaluating commands share.
//!
//! A parse does not exit the process on a usage error: it returns
//! `error.Usage` with the message and suggestion on the `Args`, and the
//! command reports it once (`Args.report`).
//!
//! `iets diff` still parses its own flags.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Diag = @import("../diag.zig").Diag;
const Session = @import("../session.zig").Session;
const config = @import("../config.zig");
const api = @import("../api.zig");
const help = @import("help.zig");
const lint = @import("../lint.zig");

/// `Reported`: a failure the parse reported itself, its exit code on
/// `Args.code`.
pub const Error = error{ Usage, Help, Reported, OutOfMemory };

/// The arguments, with `next` taking a flag's value.
pub const Args = struct {
    s: *Session,
    arena: Allocator,
    /// The command word, for the hint and the flag suggestions.
    cmd: []const u8,
    /// A native command, not classic mode: `-IP=PATH`, `-f` and `--help`
    /// are iets's own spellings there.
    native: bool = true,
    argv: []const []const u8,
    i: usize = 0,
    /// The message of a usage error, in `arena`.
    msg: []const u8 = "",
    maybe: ?[]const u8 = null,
    /// The exit code of a failure already reported (`error.Reported`).
    code: u8 = 0,

    /// The value of `flag`, the next argument.
    pub fn next(a: *Args, flag: []const u8) Error![]const u8 {
        a.i += 1;
        if (a.i < a.argv.len) return a.argv[a.i];
        const expr = std.mem.eql(u8, flag, "-E") or std.mem.eql(u8, flag, "--expr");
        return a.fail("{s} needs {s}", .{ flag, if (expr) "an expression" else "a value" });
    }

    /// A usage error with the message `fmt`.
    pub fn fail(a: *Args, comptime fmt: []const u8, args: anytype) Error {
        a.msg = try std.fmt.allocPrint(a.arena, fmt, args);
        return error.Usage;
    }

    /// An unknown flag, with the closest flag of the command's help.
    pub fn unknownFlag(a: *Args, flag: []const u8) Error {
        if (a.native) a.maybe = try help.suggest(a.arena, flag, help.flagNames(a.cmd));
        return a.fail("unknown flag '{s}'", .{flag});
    }

    /// A failure reported with the exit code `code`.
    pub fn reported(a: *Args, code: u8) Error {
        a.code = code;
        return error.Reported;
    }

    /// The usage error reported, or the help printed; the exit code.
    pub fn report(a: *Args, e: Error) u8 {
        return switch (e) {
            error.Reported => a.code,
            error.Usage => help.usage(a.s, if (a.native) a.cmd else null, a.msg, a.maybe),
            error.OutOfMemory => help.usage(a.s, a.cmd, "out of memory", null),
            error.Help => help.help(a.s, a.cmd),
        };
    }
};

/// The evaluation input flags every command line shares
/// (common-eval-args.cc).
pub const EvalFlags = struct {
    includes: std.ArrayList([]const u8) = .empty,
    args: std.ArrayList(api.AutoArg) = .empty,
    /// `-A` in order: classic commands select each one, the others the last.
    attrs: std.ArrayList([]const u8) = .empty,
    /// `--option NAME VALUE` but `pure-eval`, and the settings a command's
    /// flags alias, in flag order.
    overrides: std.ArrayList(config.Override) = .empty,
    /// The last of `--pure-eval`, `--no-pure-eval`, `--impure` and
    /// `--option pure-eval`; null when none was given.
    pure: ?bool = null,
};

/// The flags of `evalFlag`: the tag is the word.
const EvalFlag = enum {
    @"-I",
    @"--include",
    @"-A",
    @"--attr",
    @"--arg",
    @"--argstr",
    @"--option",
    @"--log-format",
    @"--show-trace",
    @"--json-log-path",
    @"--pure-eval",
    @"--no-pure-eval",
    @"--impure",
    @"-h",
    @"--help",
};

/// True: `x` is one of the `EvalFlags` flags or a logging flag of
/// common-args.cc, its values taken. `a` is an
/// `Args`, or classic mode's `Argv`, whose `fail` falls back to the real
/// nix rather than report a usage error; each has `next(flag)` and
/// `fail(fmt, args)`.
pub fn evalFlag(a: anytype, f: *EvalFlags, x: []const u8) !bool {
    const eql = std.mem.eql;
    const native, const s: *Session, const arena: Allocator = if (@TypeOf(a.*) == Args)
        .{ a.native, a.s, a.arena }
    else
        // classic mode: Nix's clustering refuses `-IP=PATH`, and the real
        // nix prints its help
        .{ false, a.k.s, a.k.arena };
    const flag = std.meta.stringToEnum(EvalFlag, x) orelse {
        // `-IP=PATH` is iets's own spelling (docs/reference/commands.md)
        if (!native or x.len <= 2 or !std.mem.startsWith(u8, x, "-I")) return false;
        try f.includes.append(arena, x[2..]);
        return true;
    };
    switch (flag) {
        .@"-I", .@"--include" => try f.includes.append(arena, try a.next(x)),
        .@"-A", .@"--attr" => try f.attrs.append(arena, try a.next(x)),
        .@"--arg", .@"--argstr" => {
            const name = try a.next(x);
            const value = try a.next(x);
            try f.args.append(arena, .{ .name = name, .text = value, .is_str = flag == .@"--argstr" });
        },
        .@"--option" => {
            const name = try a.next(x);
            const v = try a.next(x);
            if (eql(u8, name, "pure-eval")) {
                var d: Diag = .init(s.gpa);
                defer d.deinit();
                f.pure = config.parseBool(name, v, &d) catch return a.fail("{s}", .{d.message()});
            } else if (eql(u8, name, "json-log-path")) {
                try s.log.setJsonLogPath(v);
            } else try f.overrides.append(arena, .{ .name = name, .value = v });
        },
        .@"--log-format" => {
            const v = try a.next(x);
            var d: Diag = .init(s.gpa);
            defer d.deinit();
            s.log.setFormat(v, &d) catch return a.fail("{s}", .{d.message()});
        },
        .@"--show-trace" => s.log.setShowTrace(),
        .@"--json-log-path" => try s.log.setJsonLogPath(try a.next(x)),
        .@"--pure-eval" => f.pure = true,
        .@"--no-pure-eval", .@"--impure" => f.pure = false,
        // args.cc reads flags in order, so a `--help` a flag before it asked
        // for is that flag's value, not a request for the help
        .@"-h", .@"--help" => if (native) return error.Help else return false,
    }
    return true;
}

/// The cache and worker flags every evaluating command shares.
pub fn cacheFlag(a: *Args, ea: *api.EvalArgs, x: []const u8) Error!bool {
    const flag = std.meta.stringToEnum(enum {
        @"--no-tracing-cache",
        @"--no-ir-cache",
        @"--no-cache",
        @"--workers",
        @"--cache-dir",
    }, x) orelse return false;
    switch (flag) {
        .@"--no-tracing-cache" => ea.no_tracing_cache = true,
        .@"--no-ir-cache" => ea.no_ir_cache = true,
        .@"--no-cache" => {
            ea.no_tracing_cache = true;
            ea.no_ir_cache = true;
        },
        .@"--workers" => {
            const v = try a.next(x);
            const n = std.fmt.parseInt(u32, v, 10) catch 0;
            if (n == 0) return a.fail("--workers wants a number >= 1, got '{s}'", .{v});
            // the settings path pins this too; here is where a flag would
            // override it (docs/reference/profile.md)
            if (n != 1 and a.s.settings.profile != null)
                return a.fail("a profile needs one worker, so --workers must be 1, not {d}", .{n});
            ea.workers = n;
        },
        .@"--cache-dir" => ea.cache_dir = try a.next(x),
    }
    return true;
}

/// True: the argument names a flake: a `#` or `path:`, or a directory with a
/// `flake.nix` and no `default.nix`.
pub const isFlakeRef = @import("../api/flake.zig").isFlakeRef;

/// What `parseEvalArgs` collects besides the `EvalArgs`.
pub const Parsed = struct {
    eval: api.EvalArgs,
    flags: EvalFlags,
};

/// The flags `parseEvalArgs` reads besides `evalFlag`'s and `cacheFlag`'s.
const RunFlag = enum {
    @"--strict",
    @"--json",
    @"--raw",
    @"--timings",
    @"-E",
    @"--expr",
    @"--dump-drvs",
    @"--reference-lock-file",
    @"--lint",
    @"--lint-root",
    @"--lint-scope",
    @"--lint-absolute-path-literals",
    @"--lint-short-path-literals",
    @"--lint-url-literals",
    @"--readonly-mode",
    @"--extra-experimental-features",
    @"--experimental-features",
    @"-f",
    @"--file",
};

/// The evaluation flags and the input in `argv`, which is what is left after the
/// command's own flags. Reads nix.conf for its warnings and the session's
/// copy.
pub fn parseEvalArgs(a: *Args, argv: []const []const u8) Error!Parsed {
    const eql = std.mem.eql;
    var ea: api.EvalArgs = .{ .no_tracing_cache = !a.s.settings.cache, .no_ir_cache = !a.s.settings.cache };
    var f: EvalFlags = .{};
    var lints: std.ArrayList(lint.Flag) = .empty;
    var lint_roots: std.ArrayList([]const u8) = .empty;
    var more: std.ArrayList(api.Input) = .empty;
    var xp: std.ArrayList([]const u8) = .empty;
    const saved = .{ a.argv, a.i };
    a.argv = argv;
    a.i = 0;
    defer {
        a.argv = saved[0];
        a.i = saved[1];
    }
    while (a.i < argv.len) : (a.i += 1) {
        const x = argv[a.i];
        if (try evalFlag(a, &f, x)) continue;
        if (try cacheFlag(a, &ea, x)) continue;
        const flag = std.meta.stringToEnum(RunFlag, x) orelse {
            if (x.len > 0 and x[0] == '-' and !eql(u8, x, "-")) return a.unknownFlag(x);
            try setPositional(a, &ea, &more, x);
            continue;
        };
        switch (flag) {
            .@"--strict" => ea.strict = true,
            .@"--json" => ea.json = true,
            .@"--raw" => ea.raw = true,
            .@"--timings" => ea.timings = true,
            .@"-E", .@"--expr" => try setInput(a, &ea, &more, .{ .expr = try a.next(x) }),
            .@"--dump-drvs" => ea.dump_drvs = try a.next(x),
            .@"--reference-lock-file" => ea.reference_lock_file = try a.next(x),
            .@"--lint" => try lints.append(a.arena, try lintFlag(a, try a.next(x))),
            .@"--lint-root" => try lint_roots.append(a.arena, try a.next(x)),
            .@"--lint-scope" => ea.lint_scope = try lintScope(a, try a.next(x)),
            .@"--lint-absolute-path-literals", .@"--lint-short-path-literals", .@"--lint-url-literals" => {
                // Nix's own flags, a lint each: `--lint-url-literals warn`
                const v = try a.next(x);
                const level = lint.Level.parse(v) orelse return a.fail("invalid lint mode '{s}'", .{v});
                try lints.append(a.arena, .{ .selector = x[2..], .level = level });
            },
            .@"--readonly-mode" => if (!(a.native and (eql(u8, a.cmd, "eval") or eql(u8, a.cmd, "plumbing") or eql(u8, a.cmd, "prefetch"))))
                a.s.ignored.flag(x, "this command writes to the store; 'eval' and 'eval-jobs --no-instantiate' do not") catch {},
            .@"--extra-experimental-features", .@"--experimental-features" => {
                const v = try a.next(x);
                var it = std.mem.tokenizeAny(u8, v, " \t\n\r");
                while (it.next()) |feat| {
                    if (eql(u8, feat, "parse-toml-timestamps")) ea.parse_toml_timestamps = true;
                    try xp.append(a.arena, feat);
                }
                // as a setting too, so `Session.xpOn` sees it
                try f.overrides.append(a.arena, .{ .name = x[2..], .value = v });
            },
            // a synonym for the positional FILE, in the native namespace
            // only: classic mode's argv stays Nix's
            .@"-f", .@"--file" => if (a.native)
                try setPositional(a, &ea, &more, try a.next(x))
            else
                return a.unknownFlag(x),
        }
    }
    // for its warnings, and for the session's copy that the fetcher reads
    var d: Diag = .init(a.s.gpa);
    defer d.deinit();
    a.s.loadNixConfNative(f.overrides.items, &d) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return a.fail("{s}", .{d.message()}),
    };
    a.s.ignored.flush();
    ea.includes = f.includes.items;
    ea.args = f.args.items;
    ea.pure = f.pure;
    ea.attrs = f.attrs.items;
    ea.attr = if (f.attrs.items.len > 0) f.attrs.items[f.attrs.items.len - 1] else null;
    ea.more = more.items;
    ea.lints = lints.items;
    ea.lint_roots = lint_roots.items;
    ea.xp_features = xp.items;
    return .{ .eval = ea, .flags = f };
}

/// `--lint SELECTOR=LEVEL`: the selector is checked against the registry
/// now, so a typo is a usage error before anything runs.
pub fn lintFlag(a: *Args, v: []const u8) Error!lint.Flag {
    var dg: Diag = .init(a.arena);
    return lint.parseFlag(v, &dg) catch return a.fail("--lint {s}: {s}", .{ v, dg.message() });
}

/// `--lint-scope root|all`.
pub fn lintScope(a: *Args, v: []const u8) Error!lint.Scope {
    return lint.Scope.parse(v) orelse return a.fail("--lint-scope {s}: use root or all", .{v});
}

/// The input a positional argument (or `-f`) names: a flake reference
/// when it looks like one, else a file.
fn setPositional(a: *Args, ea: *api.EvalArgs, more: *std.ArrayList(api.Input), x: []const u8) Error!void {
    return setInput(a, ea, more, if (isFlakeRef(a.s.io, x)) .{ .flake = x } else .{ .file = x });
}

/// Earlier files and flakes go to `more`. `-E` and FILE exclude each other.
fn setInput(a: *Args, ea: *api.EvalArgs, more: *std.ArrayList(api.Input), input: api.Input) Error!void {
    if (ea.input) |old| {
        if ((old == .expr) != (input == .expr)) return a.fail("-E and FILE cannot be combined", .{});
        if (old != .expr) try more.append(a.arena, old);
    }
    ea.input = input;
}

const testing = std.testing;

test "positionals and -E" {
    const s = try Session.create(testing.allocator, testing.io, .{});
    defer s.destroy();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var a: Args = .{ .s = s, .arena = arena.allocator(), .cmd = "build", .argv = &.{} };
    try testing.expectError(error.Usage, parseEvalArgs(&a, &.{ "-E", "1", "x.nix" }));
    try testing.expectEqualStrings("-E and FILE cannot be combined", a.msg);
    try testing.expectError(error.Usage, parseEvalArgs(&a, &.{"--no-ir-cach"}));
    try testing.expectEqualStrings("--no-ir-cache", a.maybe.?);
    try testing.expectError(error.Usage, parseEvalArgs(&a, &.{"-A"}));
    try testing.expectEqualStrings("-A needs a value", a.msg);
}
