//! `nix derivation show` (src/nix/derivation-show.cc, Nix 2.34.8): the JSON
//! of the store derivations the installables evaluate to, and with `-r` of
//! their whole input-derivation closure. The document is `api/drvshow.zig`'s;
//! this file is the command line and the printing. See
//! `docs/reference/classic.md`.

const std = @import("std");
const Writer = std.Io.Writer;
const Diag = @import("../../diag.zig").Diag;
const Evaluator = @import("../../eval/Evaluator.zig");
const StorePath = @import("../../store/path.zig").StorePath;
const api = @import("../../api.zig");
const classic = @import("mod.zig");
const nix = @import("nix.zig");
const Cmd = classic.Cmd;
const Stop = classic.Stop;
const Argv = classic.Argv;
const Nix = nix.Nix;

fn parse(k: *Cmd, argv: []const []const u8) Stop!Nix {
    var n: Nix = .{};
    try n.parse(k, argv, struct {
        fn own(x: *Nix, _: *Argv, s: []const u8) Stop!bool {
            const eql = std.mem.eql;
            if (eql(u8, s, "-r") or eql(u8, s, "--recursive")) {
                x.recursive = true;
            } else if (eql(u8, s, "--pretty")) {
                x.pretty = true;
            } else if (eql(u8, s, "--no-pretty")) {
                x.pretty = false;
            } else return false;
            return true;
        }
    }.own);
    // installables.cc: an InstallablesCommand with no argument takes `.`.
    if (n.installables.items.len == 0) try n.installables.append(k.arena, ".");
    try n.checkArgsWithFlake(k);
    return n;
}

/// Runs `nix derivation show`; `rest` is everything after the subcommand.
pub fn main(k: *Cmd, rest: []const []const u8) Stop!u8 {
    var n = try parse(k, rest);
    const st = try nix.nixSettings(k, &n.c, n.file != null, true);
    // nlohmann's `dump(2)` on a terminal
    const pretty = n.pretty orelse k.s.out.isTerminal();
    var r = try nix.nixRun(k, &n, st.cfg);
    // `-r` and the indentation make another document, so both are in the key
    nix.nixCache(k, &n, &r, "nix derivation show", n.recursive, pretty);
    var job: Job = .{ .k = k, .n = &n, .pretty = pretty };
    return nix.printCached(k, &r, &job);
}

const Job = struct {
    k: *Cmd,
    n: *const Nix,
    pretty: bool,
    cache: ?*api.cache.Cache = null,
    text: []const u8 = "",

    pub fn go(j: *Job, ev: *Evaluator) !u8 {
        const k = j.k;
        const s = k.s;
        var roots: std.ArrayList(StorePath) = .empty;
        for (j.n.installables.items) |what| {
            const v = try nix.resolve(ev, k, j.n, what);
            try roots.append(k.arena, try api.installable.toDerivation(ev, v, what));
        }
        var inputs: api.build.EvalInputs = .init(ev);
        defer inputs.deinit();
        var out: Writer.Allocating = .init(k.arena);
        var d: Diag = .init(s.gpa);
        defer d.deinit();
        api.drvshow.show(s.gpa, s.io, &out.writer, roots.items, j.n.recursive, j.pretty, inputs.inputs(), &d) catch |e| return classic.report(s, &d, e);
        j.text = out.written();
        if (j.cache) |c| try api.cache.writeEntry(c, s, ev, j.text, false);
        return 0;
    }
};
