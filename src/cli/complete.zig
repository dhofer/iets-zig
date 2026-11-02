//! `iets __complete WORD...` and `iets completion SHELL`: tab completion
//! from the tables the help is made of, so a new flag completes the day it
//! is documented. The scripts under `complete/` are Rust iets's verbatim.
//!
//! The protocol is cobra's: one `CANDIDATE<TAB>DESCRIPTION` per line, then
//! `:N`, the directive. The shell scripts are thin because the filtering,
//! the descriptions and the choice of what comes next all happen here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Session = @import("../session.zig").Session;
const help = @import("help.zig");
const Command = @import("../cli.zig").Command;
const Classic = @import("classic/mod.zig").Name;
const docs = @import("docs.zig");
const api = @import("../api.zig");
const installable = api.installable;
const Prefixes = installable.Prefixes;
const Evaluator = api.Evaluator;

/// The shell adds files to the candidates.
pub const default: u8 = 0;
/// The shell does not put a space after the candidate: it is not the end.
pub const no_space: u8 = 2;
/// The shell adds nothing, not even files.
pub const no_files: u8 = 4;

const scripts = .{
    .{ "bash", @embedFile("complete/iets.bash") },
    .{ "zsh", @embedFile("complete/iets.zsh") },
    .{ "fish", @embedFile("complete/iets.fish") },
    .{ "nushell", @embedFile("complete/iets.nu") },
    .{ "elvish", @embedFile("complete/iets.elv") },
    .{ "powershell", @embedFile("complete/iets.ps1") },
};

pub const shells = [_][]const u8{ "bash", "zsh", "fish", "nushell", "elvish", "powershell" };

/// `iets completion SHELL`.
pub fn cmdCompletion(s: *Session, argv: []const []const u8) u8 {
    if (argv.len == 0) return help.unknownSubcommand(s, null, &shells);
    if (argv.len == 1) inline for (scripts) |e| if (std.mem.eql(u8, argv[0], e[0])) return help.out(s, e[1]);
    return help.unknownSubcommand(s, argv[0], &shells);
}

/// `iets __complete WORD...`: `words` are the arguments after `iets`, the
/// last one the word under the cursor (possibly empty).
pub fn cmdComplete(c: *const Ctx, words: []const []const u8) u8 {
    var arena: std.heap.ArenaAllocator = .init(c.s.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const r = complete(c, a, words) catch return 1;
    var out: std.Io.Writer.Allocating = .init(a);
    for (r.cands) |cand| {
        out.writer.writeAll(cand.name) catch return 1;
        if (cand.about.len > 0) out.writer.print("\t{s}", .{cand.about}) catch return 1;
        out.writer.writeByte('\n') catch return 1;
    }
    out.writer.print(":{d}\n", .{r.directive}) catch return 1;
    return help.out(c.s, out.written());
}

/// What attribute completion evaluates with.
pub const Ctx = struct {
    s: *Session,
    init: *const std.process.Init,
};

pub const Cand = struct { name: []const u8, about: []const u8 = "" };
pub const Result = struct { cands: []const Cand, directive: u8 };

/// The names that start with `cur`, once each.
const Pairs = struct {
    a: Allocator,
    cur: []const u8,
    out: std.ArrayList(Cand) = .empty,

    fn add(p: *Pairs, name: []const u8, about: []const u8) !void {
        if (!std.mem.startsWith(u8, name, p.cur)) return;
        for (p.out.items) |o| if (std.mem.eql(u8, o.name, name)) return;
        try p.out.append(p.a, .{ .name = name, .about = about });
    }
};

/// What a placeholder says about the value: a path, or a fixed set of
/// words when it is spelled `A|B`.
const Kind = enum { path, words, other };

fn kind(placeholder: []const u8) Kind {
    if (std.mem.indexOfScalar(u8, placeholder, '|') != null) return .words;
    for ([_][]const u8{ "FILE", "DIR", "PATH", "ENTRY", "P=PATH", "SP=LOCAL" }) |p| if (std.mem.eql(u8, placeholder, p)) return .path;
    if (std.mem.endsWith(u8, placeholder, "FILE") or std.mem.endsWith(u8, placeholder, "DIR")) return .path;
    return .other;
}

fn firstWord(a: Allocator, cur: []const u8) ![]const Cand {
    var p: Pairs = .{ .a = a, .cur = cur };
    if (std.mem.startsWith(u8, cur, "-")) {
        try p.add("--help", "");
        try p.add("--version", "");
        return p.out.items;
    }
    for (help.summaries) |sum| try p.add(sum.name, sum.about);
    try p.add("help", "print a command's or a topic's page");
    try p.add("version", "print the version");
    for (help.classic_names) |n| try p.add(n, "act like the Nix command");
    return p.out.items;
}

const none: []const Cand = &.{};

/// The candidates for the last of `words` and the directive.
pub fn complete(c: *const Ctx, a: Allocator, words: []const []const u8) !Result {
    if (words.len == 0) return .{ .cands = none, .directive = no_files };
    const cur = words[words.len - 1];
    const before = words[0 .. words.len - 1];
    if (before.len == 0) return .{ .cands = try firstWord(a, cur), .directive = no_files };
    const word = before[0];
    const rest = before[1..];
    var p: Pairs = .{ .a = a, .cur = cur };

    if (std.mem.eql(u8, word, "help")) {
        if (rest.len > 0) return .{ .cands = none, .directive = no_files };
        for (help.summaries) |sum| try p.add(sum.name, sum.about);
        for (docs.pages) |pg| try p.add(pg.topic, "topic");
        return .{ .cands = p.out.items, .directive = no_files };
    }
    // the real command's own flags are not ours to know
    if (Classic.fromWord(word) != null) return .{ .cands = none, .directive = default };
    const cmd = help.commandOf(word) orelse return .{ .cands = none, .directive = no_files };

    switch (cmd) {
        .completion => {
            if (rest.len == 0) for (shells) |sh| try p.add(sh, "");
            return .{ .cands = p.out.items, .directive = no_files };
        },
        .cache => if (rest.len == 0) {
            try p.add("gc", "remove the cache entries nobody read lately");
            try p.add("dump", "print the read set of an entry");
            try p.add("paths", "print what to watch for an entry");
            return .{ .cands = p.out.items, .directive = no_files };
        },
        .lint => if (rest.len == 0) {
            try p.add("list", "print the lint registry");
            return .{ .cands = p.out.items, .directive = no_files };
        },
        else => {},
    }

    const table = help.flagsOf(cmd);
    if (pending(table, before)) |pend| {
        const f = pend.flag;
        if (isAttr(f.name)) {
            const in = rootInput(table, before) orelse return .{ .cands = none, .directive = no_files };
            return .{ .cands = try namesOf(a, try attrPath(c, a, in, cur)), .directive = no_space | no_files };
        }
        const ph = f.values[pend.n];
        switch (kind(ph)) {
            .path => return .{ .cands = none, .directive = default },
            .words => {
                var it = std.mem.splitScalar(u8, ph, '|');
                while (it.next()) |w| try p.add(w, "");
                return .{ .cands = p.out.items, .directive = no_files };
            },
            .other => return .{ .cands = none, .directive = no_files },
        }
    }
    if (std.mem.indexOfScalar(u8, cur, '#') != null and !std.mem.startsWith(u8, cur, "-")) {
        if (fragmentPrefixes(cmd)) |pre| return .{ .cands = try namesOf(a, try flakeFragment(c, a, pre, cur)), .directive = no_space | no_files };
    }
    if (std.mem.startsWith(u8, cur, "-")) {
        for (table) |f| try p.add(f.name, f.about);
        try p.add("--help", "print the flags of the command");
        return .{ .cands = p.out.items, .directive = no_files };
    }
    // a file, a flake reference or an expression: the shell knows files
    return .{ .cands = none, .directive = default };
}

fn namesOf(a: Allocator, names: []const []const u8) ![]const Cand {
    const out = try a.alloc(Cand, names.len);
    for (names, out) |n, *o| o.* = .{ .name = n };
    return out;
}

/// What `-A` selects from: `-E EXPR`, `-f FILE` or the first positional,
/// whichever the words before the cursor name. A flake reference has its
/// own fragment, so it is not one.
fn rootInput(table: []const help.Flag, before: []const []const u8) ?api.Input {
    var positional: ?[]const u8 = null;
    var i: usize = 1;
    while (i < before.len) {
        const w = before[i];
        var flag: ?help.Flag = null;
        for (table) |f| if (std.mem.eql(u8, f.name, w)) {
            flag = f;
            break;
        };
        if (i + 1 < before.len) {
            const eql = std.mem.eql;
            if (eql(u8, w, "-E") or eql(u8, w, "--expr")) return .{ .expr = before[i + 1] };
            if (eql(u8, w, "-f") or eql(u8, w, "--file")) return .{ .file = before[i + 1] };
        }
        i += 1 + if (flag) |f| f.values.len else 0;
        if (flag == null and !std.mem.startsWith(u8, w, "-") and positional == null) positional = w;
    }
    const pos = positional orelse return null;
    if (std.mem.indexOfScalar(u8, pos, '#') != null) return null;
    return .{ .file = pos };
}

/// The prefixes the fragment of a command's flake reference is tried
/// under; null for a command whose installable is not a flake output.
fn fragmentPrefixes(cmd: Command) ?Prefixes {
    return switch (cmd) {
        .build, .eval => .package,
        .@"print-dev-env" => .dev_shell,
        .search => .package_set,
        else => null,
    };
}

fn isAttr(w: []const u8) bool {
    return std.mem.eql(u8, w, "-A") or std.mem.eql(u8, w, "--attr");
}

const Pending = struct { flag: help.Flag, n: usize };

/// The flag that still wants values among the `before` the cursor, and
/// the index of the value under the cursor.
fn pending(table: []const help.Flag, before: []const []const u8) ?Pending {
    var max: usize = 0;
    for (table) |f| max = @max(max, f.values.len);
    var back: usize = 1;
    while (back <= @min(max, before.len)) : (back += 1) {
        const word = before[before.len - back];
        for (table) |f| if (std.mem.eql(u8, f.name, word)) {
            return if (f.values.len >= back) .{ .flag = f, .n = back - 1 } else null;
        };
    }
    return null;
}

// Attribute completion: it evaluates, so it is limited
// in time (`IETS_COMPLETE_MS`) and silent on stderr.

var answered: std.atomic.Value(bool) = .init(false);

/// `FLAKEREF#fragment`: the names, each after the reference and `#`.
fn flakeFragment(c: *const Ctx, a: Allocator, p: Prefixes, word: []const u8) ![]const []const u8 {
    const hash = std.mem.indexOfScalar(u8, word, '#') orelse return &.{};
    const loc = word[0..hash];
    const at = if (loc.len == 0) "." else loc;
    const args: api.EvalArgs = .{ .input = .{ .flake = at }, .no_tracing_cache = true, .workers = 1 };
    const names = try guarded(c, a, &args, .{ .flake = .{ .loc = at, .p = p, .fragment = word[hash + 1 ..] } });
    const out = try a.alloc([]const u8, names.len);
    for (names, out) |n, *o| o.* = try std.mem.concat(a, u8, &.{ loc, "#", n });
    return out;
}

/// `-A PREFIX` under the root `in`.
fn attrPath(c: *const Ctx, a: Allocator, in: api.Input, prefix: []const u8) ![]const []const u8 {
    const args: api.EvalArgs = .{ .input = in, .no_tracing_cache = true, .workers = 1 };
    return guarded(c, a, &args, .{ .attr = prefix });
}

/// What a completion evaluates: `-A`'s prefix under the input, or a flake
/// fragment.
const What = union(enum) {
    attr: []const u8,
    flake: struct { loc: []const u8, p: Prefixes, fragment: []const u8 },
};

const Job = struct {
    a: Allocator,
    args: *const api.EvalArgs,
    what: What,
    cwd: []const u8,
    names: []const []const u8 = &.{},

    fn go(j: *Job, ev: *Evaluator) !u8 {
        j.names = switch (j.what) {
            .attr => |prefix| installable.completeInInput(ev, j.a, j.args.input.?, prefix, j.cwd),
            .flake => |f| installable.completeInFlake(ev, j.a, f.loc, f.p, f.fragment, j.cwd),
        } catch &.{};
        return 0;
    }
};

fn guarded(c: *const Ctx, a: Allocator, args: *const api.EvalArgs, what: What) ![]const []const u8 {
    var sink: std.Io.Writer.Discarding = .init(&.{});
    c.s.log.writeTo(&sink.writer);
    watchdog(c.s);
    const run: api.run.Run = .{ .s = c.s, .init = c.init, .args = args, .keep_aterm = false, .keep_site = false };
    var job: Job = .{ .a = a, .args = args, .what = what, .cwd = try run.cwd() };
    _ = run.go(&job, Job.go);
    // the watchdog answered first: it exits the process
    if (answered.swap(true, .seq_cst)) while (true) std.Thread.yield() catch {};
    return job.names;
}

fn watchdog(s: *Session) void {
    const ms = s.settings.complete_ms;
    if (ms == 0) return;
    const T = struct {
        fn run(ses: *Session, wait: u64) void {
            std.Io.sleep(ses.io, .fromMilliseconds(@intCast(wait)), .awake) catch {};
            if (!answered.swap(true, .seq_cst)) {
                var buf: [8]u8 = undefined;
                ses.out.writeAll(std.fmt.bufPrint(&buf, ":{d}\n", .{no_space | no_files}) catch ":6\n") catch {};
                std.process.exit(0);
            }
        }
    };
    const t = std.Thread.spawn(.{}, T.run, .{ s, ms }) catch return;
    t.detach();
}

const testing = std.testing;

fn runFor(words: []const []const u8) !struct { names: []const []const u8, d: u8, arena: std.heap.ArenaAllocator } {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const c: Ctx = .{ .s = undefined, .init = undefined };
    const r = try complete(&c, a, words);
    const names = try a.alloc([]const u8, r.cands.len);
    for (r.cands, names) |x, *n| n.* = x.name;
    return .{ .names = names, .d = r.directive, .arena = arena };
}

fn expectNames(want: []const []const u8, words: []const []const u8) !void {
    var r = try runFor(words);
    defer r.arena.deinit();
    try testing.expectEqual(want.len, r.names.len);
    for (want, r.names) |w, n| try testing.expectEqualStrings(w, n);
}

fn expectEmpty(d: u8, words: []const []const u8) !void {
    var r = try runFor(words);
    defer r.arena.deinit();
    try testing.expectEqual(0, r.names.len);
    try testing.expectEqual(d, r.d);
}

fn has(words: []const []const u8, want: []const u8) !bool {
    var r = try runFor(words);
    defer r.arena.deinit();
    for (r.names) |n| if (std.mem.eql(u8, n, want)) return true;
    return false;
}

test "commands complete with their summary" {
    try expectNames(&.{"build"}, &.{"bu"});
    try expectNames(&.{"nix-build"}, &.{"nix-b"});
    for ([_][]const u8{ "eval", "completion", "help", "version", "nix-shell" }) |w| try testing.expect(try has(&.{""}, w));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const c: Ctx = .{ .s = undefined, .init = undefined };
    const r = try complete(&c, arena.allocator(), &.{"ev"});
    try testing.expectEqualStrings("evaluate an expression or a file and print the value", r.cands[0].about);
    try testing.expectEqual(no_files, r.directive);
}

test "flags complete after a dash" {
    try expectNames(&.{"--strict"}, &.{ "eval", "--st" });
    try testing.expect(try has(&.{ "build", "--no-" }, "--no-build"));
    try testing.expect(try has(&.{ "build", "--no-" }, "--no-cache"));
    try expectNames(&.{"--help"}, &.{ "eval", "--he" });
}

test "a flag value completes by its placeholder" {
    try expectEmpty(default, &.{ "eval", "--file", "" });
    try expectEmpty(default, &.{ "eval", "-f", "x" });
    try expectEmpty(default, &.{ "cache", "gc", "--cache-dir", "" });
    // the second value of --arg is an expression, not a path
    try expectEmpty(no_files, &.{ "eval", "--arg", "n", "" });
    // a value is not a flag
    try expectEmpty(no_files, &.{ "eval", "--workers", "-" });
    // once the values are in, the flags are back
    try expectNames(&.{"--json"}, &.{ "eval", "--arg", "n", "1", "--js" });
}

test "subcommands and topics" {
    try expectNames(&.{ "gc", "dump", "paths" }, &.{ "cache", "" });
    try expectNames(&.{"fish"}, &.{ "completion", "f" });
    try expectNames(&shells, &.{ "completion", "" });
    try expectEmpty(no_files, &.{ "completion", "fish", "" });
    try testing.expect(try has(&.{ "help", "bui" }, "build"));
    try expectEmpty(no_files, &.{ "help", "build", "" });
}

test "a positional is left to the shell" {
    try expectEmpty(default, &.{ "eval", "" });
    try expectEmpty(default, &.{ "nix-build", "" });
    try expectEmpty(no_files, &.{ "bogus", "" });
}

test "every script asks the binary" {
    inline for (scripts) |e| try testing.expect(std.mem.indexOf(u8, e[1], "__complete") != null);
}
