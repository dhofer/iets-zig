//! What a run owns. A library must not keep this
//! in process-wide statics: two evaluators in one process each want their
//! own settings, their own log destination and their own mismatch list.
//!
//! The session is passed explicitly: fibers migrate between threads, so a
//! thread-local on a force path could name another run's session.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Diag = @import("diag.zig").Diag;
const Env = @import("env.zig").Env;
const Log = @import("log.zig").Log;
const Stdout = @import("stdout.zig").Stdout;
const Events = @import("events.zig").Events;
const Profile = @import("profile.zig").Profile;
const Ignored = @import("ignored.zig").Ignored;
const settings_ = @import("settings.zig");
const Settings = settings_.Settings;
const config = @import("config.zig");
const SourceMap = @import("provenance.zig").SourceMap;

pub const Session = struct {
    gpa: Allocator,
    io: std.Io,
    env: Env,
    log: Log,
    out: Stdout,
    /// This run's sampled flame graph (`profile.zig`).
    profile: Profile,
    /// Where this run's instrumentation events go (`events.zig`).
    events: Events,
    /// What this run was asked for and does not do (`ignored.zig`).
    ignored: Ignored,
    /// The environment knobs alone until `loadSettings` reads the files.
    settings: Settings,
    /// nix.conf, read once per run: it cannot change under an evaluation.
    nix_conf: ?config.Config = null,
    /// Store path to local tree, for the commands that build the map while
    /// the evaluation is live (`provenance.zig`).
    source_map: ?SourceMap = null,
    /// The `parse-toml-timestamps` experimental feature.
    toml_timestamps: bool = false,
    /// A host asked `exit` to come back to it instead of ending the process.
    catch_exit: bool = false,
    // The tree store, the eval-jobs walk and the library's heap are not
    // here: a run passes them explicitly (`Evaluator.Config.inputs`,
    // `jobs.Walk`, the run's arenas), as fibers migrate between threads.

    /// A session on the heap: its log and boards point back into it.
    pub fn create(gpa: Allocator, io: std.Io, env: Env) !*Session {
        const s = try gpa.create(Session);
        s.* = .{
            .gpa = gpa,
            .io = io,
            .env = env,
            .log = .init(gpa, io, env),
            .out = .{ .io = io },
            .profile = .init(gpa, io),
            .events = .init(gpa, io),
            .ignored = .init(gpa, io),
            .settings = .default(gpa, io, env, null),
        };
        s.log.attach();
        s.ignored.log = &s.log;
        return s;
    }

    pub fn destroy(s: *Session) void {
        if (s.source_map) |*m| m.deinit();
        if (s.nix_conf) |*c| c.deinit();
        s.settings.deinit();
        s.ignored.deinit();
        s.events.deinit();
        s.profile.deinit();
        s.log.deinit();
        s.gpa.destroy(s);
    }

    /// Reads the `iets.toml` settings files and applies the `--iets-option`
    /// pairs. Call it once, before anything reads a setting.
    pub fn loadSettings(s: *Session, options: []const settings_.Pair, d: *Diag) !void {
        const n = try Settings.load(s.gpa, s.io, s.env, options, &s.log, d);
        s.settings.deinit();
        s.settings = n;
    }

    /// What a run starts once the settings are read:
    /// the progress switch, the event stream and the profile.
    pub fn open(s: *Session) void {
        s.log.progress.setHidden(!s.settings.progress);
        s.events.open(s.settings.events, s.settings.events_to, &s.log);
        if (s.settings.profile) |m| s.profile.open(m, s.settings.profile_to orelse "-", s.settings.profile_hz);
    }

    /// What ends a run: the profile is written.
    pub fn finish(s: *Session) void {
        s.profile.write(&s.log);
    }

    /// The whole nix.conf discovery (`Config.read`), then what follows once
    /// the settings are read: a warning for each
    /// setting that has no effect, `show-trace`, and the session's copy.
    pub fn loadNixConf(s: *Session, overrides: []const config.Override, d: *Diag) !void {
        var c = try config.Config.read(s.gpa, s.io, s.env, overrides, d);
        errdefer c.deinit();
        try c.noteIgnored(&s.ignored);
        if (c.boolean("show-trace", d) catch null orelse false) s.log.setShowTrace();
        if (s.nix_conf == null) s.nix_conf = c else c.deinit();
        s.ignored.flush();
    }

    /// `loadNixConf` for iets's own commands, which send a daemon no settings.
    pub fn loadNixConfNative(s: *Session, overrides: []const config.Override, d: *Diag) !void {
        const why = "iets's own commands send a daemon no settings; classic mode does";
        try config.noteUnsent(&s.ignored, overrides, &.{}, why);
        return s.loadNixConf(overrides, d);
    }

    /// Whether an experimental feature is on for this run: nix.conf's
    /// `experimental-features`, plus what the command line added. Only
    /// classic mode asks; before the settings are read nothing is on.
    pub fn xpOn(s: *const Session, feature: []const u8) bool {
        const c = s.nix_conf orelse return false;
        return c.listHas("experimental-features", feature);
    }

    /// Whether an evaluation may read a derivation output that is already
    /// in the store. Nix refuses that read when `allow-import-from-derivation`
    /// is off and warns with `trace-import-from-derivation`, so both leave it
    /// to the real nix.
    pub fn readsBuiltOutputs(s: *const Session) bool {
        const c = s.nix_conf orelse return true;
        var d: Diag = .init(s.gpa);
        defer d.deinit();
        const ifd = c.boolean("allow-import-from-derivation", &d) catch null;
        const trace = c.boolean("trace-import-from-derivation", &d) catch null;
        return ifd != false and trace != true;
    }
};

const testing = std.testing;

test "two sessions share no state" {
    const line = @import("log.zig").mismatch_text ++ ":\n  specified: sha256-A=\n     got:    sha256-B=";
    const a = try Session.create(testing.allocator, testing.io, .{});
    defer a.destroy();
    const b = try Session.create(testing.allocator, testing.io, .{});
    defer b.destroy();
    a.log.noteMismatch(line);
    _ = a.log.resolveMismatches({}, struct {
        fn f(_: void, _: []const u8) bool {
            return true;
        }
    }.f);
    const none = try b.log.takeMismatches();
    defer b.log.freePairs(none);
    try testing.expectEqual(0, none.len);
    const one = try a.log.takeMismatches();
    defer a.log.freePairs(one);
    try testing.expectEqual(1, one.len);
}

test "nix.conf warnings go through the session's log" {
    var m = try @import("env.zig").fromPairs(testing.allocator, &.{
        .{ "NIX_CONF_DIR", "/nonexistent" },
        .{ "NIX_USER_CONF_FILES", "" },
        .{ "NIX_CONFIG", "bogus-setting = 1\ntrace-verbose = true\nshow-trace = true\nexperimental-features = flakes" },
    });
    defer m.deinit();
    const s = try Session.create(testing.allocator, testing.io, .process(&m));
    defer s.destroy();
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    s.log.writeTo(&buf.writer);
    s.log.stderr_tty = false;
    s.log.sink_state = .none;
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    try s.loadNixConfNative(&.{.{ .name = "keep-outputs", .value = "true" }}, &d);
    try testing.expectEqualStrings(
        "warning: setting 'keep-outputs' is ignored: iets's own commands send a daemon no settings; classic mode does\n" ++
            "warning: unknown setting 'bogus-setting'\n" ++
            "warning: setting 'trace-verbose' is ignored: builtins.traceVerbose never prints\n",
        buf.written(),
    );
    try testing.expect(s.log.show_trace.load(.monotonic));
    try testing.expect(s.xpOn("flakes") and !s.xpOn("nix-command"));
    try testing.expect(s.readsBuiltOutputs());
}
