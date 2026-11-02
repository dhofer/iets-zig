//! The command line: one file per command. Ported from ../iets/src/cli/.
//! `run.zig` is the entry `main` calls; `dispatch` takes the command word.

const std = @import("std");
const Session = @import("session.zig").Session;

pub const args = @import("cli/args.zig");
pub const help = @import("cli/help.zig");
pub const docs = @import("cli/docs.zig");
pub const complete = @import("cli/complete.zig");
pub const run = @import("cli/run.zig");
pub const eval = @import("cli/eval.zig");
pub const parse = @import("cli/parse.zig");
pub const lint = @import("cli/lint.zig");
pub const build = @import("cli/build.zig");
pub const diff = @import("cli/diff.zig");
pub const devenv = @import("cli/devenv.zig");
pub const devenv_hooks = @import("cli/devenv_hooks.zig");
pub const jobs = @import("cli/jobs.zig");
pub const plumbing = @import("cli/plumbing.zig");
pub const render = @import("cli/render.zig");
pub const cache = @import("cli/cache.zig");
pub const search = @import("cli/search.zig");
pub const prefetch = @import("cli/prefetch.zig");
pub const classic = @import("cli/classic/mod.zig");

/// What a command gets: the session, the process (its environment, I/O and
/// arena) and the arguments after the command word.
pub const Ctx = struct {
    s: *Session,
    init: *const std.process.Init,
};

/// The native commands, in the overview's order: the tag is the word.
pub const Command = enum {
    eval,
    build,
    search,
    diff,
    @"eval-jobs",
    @"print-dev-env",
    prefetch,
    plumbing,
    lint,
    parse,
    cache,
    completion,

    pub fn fromWord(word: []const u8) ?Command {
        return std.meta.stringToEnum(Command, word);
    }
};

/// The native command `cmd` with `argv`, the arguments after it.
pub fn dispatch(c: *const Ctx, cmd: Command, argv: []const []const u8) u8 {
    return switch (cmd) {
        .eval => eval.cmd(c, argv),
        .build => build.cmd(c, argv),
        .search => search.cmd(c, argv),
        .diff => diff.cmd(c, argv),
        .@"eval-jobs" => jobs.cmd(c, argv),
        .@"print-dev-env" => devenv.cmd(c, argv),
        .prefetch => prefetch.cmd(c, argv),
        .plumbing => plumbing.cmd(c, argv),
        .lint => lint.cmd(c, argv),
        .parse => parse.cmd(c, argv),
        .cache => cache.cmd(c, argv),
        .completion => complete.cmdCompletion(c.s, argv),
    };
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("cli/layering.zig");
}
