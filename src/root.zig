//! iets: a Nix evaluator. The library root; `main.zig` is the command line on top.

pub const diag = @import("diag.zig");
pub const bytes = @import("bytes.zig");
pub const store = @import("store.zig");
pub const syntax = @import("syntax.zig");
pub const runtime = @import("runtime.zig");
pub const eval = @import("eval.zig");
pub const compile = @import("compile.zig");
pub const builtins = @import("builtins.zig");
pub const Scratch = @import("Scratch.zig");
pub const Heap = @import("Heap.zig");
pub const cachefs = @import("cachefs.zig");
pub const ir_cache = @import("ir_cache.zig");
pub const trace = @import("trace.zig");
pub const fetch = @import("fetch.zig");
pub const treestore = @import("treestore.zig");
pub const flakeref = @import("flake/flakeref.zig");
pub const flake = @import("flake.zig");
pub const source = @import("source.zig");
pub const remote = @import("remote.zig");
pub const build = @import("build.zig");
pub const api = @import("api.zig");
pub const jobs = @import("jobs.zig");
pub const devenv = @import("devenv.zig");
pub const cli = @import("cli.zig");
pub const lint = @import("lint.zig");
// The outer layers' infrastructure.
pub const env = @import("env.zig");
pub const argv = @import("argv.zig");
pub const sys = @import("sys.zig");
pub const errors = @import("errors.zig");
pub const display = @import("display.zig");
pub const progress = @import("progress.zig");
pub const log = @import("log.zig");
pub const config = @import("config.zig");
pub const ignored = @import("ignored.zig");
pub const events = @import("events.zig");
pub const profile = @import("profile.zig");
pub const settings = @import("settings.zig");
pub const project = @import("project.zig");
pub const nixbin = @import("nixbin.zig");
pub const provenance = @import("provenance.zig");
pub const stdout = @import("stdout.zig");
pub const session = @import("session.zig");

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(store);
    std.testing.refAllDecls(syntax);
    std.testing.refAllDecls(eval);
    std.testing.refAllDecls(fetch);
    std.testing.refAllDecls(treestore);
    _ = flakeref;
    std.testing.refAllDecls(source);
    std.testing.refAllDecls(flake);
    std.testing.refAllDecls(remote);
    std.testing.refAllDecls(build);
    std.testing.refAllDecls(api);
    std.testing.refAllDecls(devenv);
    std.testing.refAllDecls(cli);
    std.testing.refAllDecls(lint);
    std.testing.refAllDecls(sys);
}
