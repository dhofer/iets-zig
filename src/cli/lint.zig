//! `iets lint list [--lint SELECTOR=LEVEL]... [--lint-root DIR]...
//! [--lint-scope root|all] [PATH]`: the registry with the levels a run from
//! `PATH` (default: cwd) would use.

const std = @import("std");
const cli = @import("../cli.zig");
const help = @import("help.zig");
const args_mod = @import("args.zig");
const api = @import("../api.zig");
const lint = @import("../lint.zig");
const Diag = @import("../diag.zig").Diag;

pub fn cmd(c: *const cli.Ctx, argv: []const []const u8) u8 {
    const s = c.s;
    if (argv.len == 0 or !std.mem.eql(u8, argv[0], "list"))
        return help.unknownSubcommand(s, if (argv.len > 0) argv[0] else null, &.{"list"});
    const arena = c.init.arena.allocator();
    var a: args_mod.Args = .{ .s = s, .arena = arena, .cmd = "lint", .argv = argv };
    const ea = parse(&a) catch |e| return a.report(e);
    const run: api.run.Run = .{ .s = s, .init = c.init, .args = &ea };
    const cwd = run.cwd() catch return 1;
    const cfg = (api.run.lintConfig(&run, cwd) catch return 1) orelse return 1;
    var out: std.Io.Writer.Allocating = .init(arena);
    cfg.list(&out.writer) catch return 1;
    return help.out(s, out.written());
}

fn parse(a: *args_mod.Args) args_mod.Error!api.EvalArgs {
    var ea: api.EvalArgs = .{};
    var lints: std.ArrayList(lint.Flag) = .empty;
    var roots: std.ArrayList([]const u8) = .empty;
    a.i = 1;
    while (a.i < a.argv.len) : (a.i += 1) {
        const x = a.argv[a.i];
        if (std.mem.eql(u8, x, "--lint")) {
            try lints.append(a.arena, try args_mod.lintFlag(a, try a.next(x)));
        } else if (std.mem.eql(u8, x, "--lint-root")) {
            try roots.append(a.arena, try a.next(x));
        } else if (std.mem.eql(u8, x, "--lint-scope")) {
            ea.lint_scope = try args_mod.lintScope(a, try a.next(x));
        } else if (x.len > 0 and x[0] == '-') {
            return a.unknownFlag(x);
        } else ea.input = .{ .file = x };
    }
    ea.lints = lints.items;
    ea.lint_roots = roots.items;
    return ea;
}
