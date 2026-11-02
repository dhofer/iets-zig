//! Nix's settings files, read the way Nix reads them.
//!
//! Discovery follows libstore/globals.cc:loadConfFile; the line syntax
//! follows libutil/configuration.cc:parseConfigFiles. Every value stays a raw
//! string: the typed getters below apply the same parse rules Nix's
//! `BaseSetting` specialisations do. Settings this crate does not know are
//! kept, not dropped (Nix warns about them and keeps them in
//! `unknownSettings`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Diag = @import("diag.zig").Diag;
const Env = @import("env.zig").Env;
const errors = @import("errors.zig");
const Error = errors.Error;
const ignored = @import("ignored.zig");

/// Settings whose values are whitespace-separated lists, so `extra-<name>`
/// appends instead of replacing (configuration.cc:Config::set, `isAppendable`).
const appendable = [_][]const u8{
    "access-tokens",         "allowed-uris",    "allowed-users",       "build-hook",
    "experimental-features", "extra-platforms", "hashed-mirrors",      "ignored-acls",
    "impure-env",            "nix-path",        "sandbox-paths",       "secret-key-files",
    "substituters",          "system-features", "trusted-public-keys", "trusted-substituters",
    "trusted-users",
};

/// Every setting of Nix 2.34.8 (`nix config show`); `aliases` has the old
/// names. A name in neither list is `warning: unknown setting 'NAME'`, the
/// text Nix gives (configuration.cc:warnUnknownSettings).
const known =
    \\abort-on-warn accept-flake-config access-tokens allow-dirty
    \\allow-dirty-locks allow-import-from-derivation allow-new-privileges
    \\allow-symlinked-store allow-unsafe-native-code-during-evaluation
    \\allowed-impure-host-deps allowed-uris allowed-users
    \\always-allow-substitutes auto-allocate-uids auto-optimise-store
    \\bash-prompt bash-prompt-prefix bash-prompt-suffix build-dir build-hook
    \\build-poll-interval build-users-group builders builders-use-substitutes
    \\commit-lock-file-summary compress-build-log connect-timeout cores
    \\debugger-on-trace debugger-on-warn diff-hook download-attempts
    \\download-buffer-size download-speed
    \\eval-attrset-update-layer-rhs-threshold eval-cache eval-profile-file
    \\eval-profiler eval-profiler-frequency eval-system experimental-features
    \\external-builders extra-platforms fallback filter-syscalls
    \\flake-registry fsync-metadata fsync-store-paths gc-reserved-space
    \\hashed-mirrors http-connections http2 id-count ignore-try ignored-acls
    \\impersonate-linux-26 impure-env json-log-path keep-build-log
    \\keep-derivations keep-env-derivations keep-failed keep-going
    \\keep-outputs lint-absolute-path-literals lint-short-path-literals
    \\lint-url-literals log-lines max-build-log-size max-call-depth max-free
    \\max-jobs max-silent-time max-substitution-jobs min-free
    \\min-free-check-interval nar-buffer-size narinfo-cache-meta-ttl
    \\narinfo-cache-negative-ttl narinfo-cache-positive-ttl netrc-file
    \\nix-path nix-shell-always-looks-for-shell-nix
    \\nix-shell-shebang-arguments-relative-to-script plugin-files
    \\post-build-hook pre-build-hook preallocate-contents print-missing
    \\pure-eval require-drop-supplementary-groups require-sigs restrict-eval
    \\run-diff-hook sandbox sandbox-build-dir sandbox-dev-shm-size
    \\sandbox-fallback sandbox-paths secret-key-files show-trace
    \\ssl-cert-file stalled-download-timeout start-id store substitute
    \\substituters sync-before-registering system system-features tarball-ttl
    \\timeout trace-function-calls trace-import-from-derivation trace-verbose
    \\trust-tarballs-from-git-forges trusted-public-keys trusted-substituters
    \\trusted-users upgrade-nix-store-path-url use-case-hack use-cgroups
    \\use-registries use-sqlite-wal use-xdg-base-directories
    \\user-agent-suffix warn-dirty warn-large-path-threshold
    \\warn-short-path-literals
;

/// The Boolean settings of Nix 2.34.8 (`nix config show`). Nix parses a
/// value the moment it is set, so a spelling outside `parseBool` stops the run.
const bools =
    \\abort-on-warn accept-flake-config allow-dirty allow-dirty-locks
    \\allow-import-from-derivation allow-new-privileges allow-symlinked-store
    \\allow-unsafe-native-code-during-evaluation always-allow-substitutes
    \\auto-allocate-uids auto-optimise-store builders-use-substitutes
    \\compress-build-log debugger-on-trace debugger-on-warn eval-cache fallback
    \\filter-syscalls fsync-metadata fsync-store-paths http2 ignore-try
    \\impersonate-linux-26 keep-build-log keep-derivations keep-env-derivations
    \\keep-failed keep-going keep-outputs nix-shell-always-looks-for-shell-nix
    \\nix-shell-shebang-arguments-relative-to-script preallocate-contents
    \\print-missing pure-eval require-drop-supplementary-groups require-sigs
    \\restrict-eval run-diff-hook sandbox-fallback show-trace substitute
    \\sync-before-registering trace-function-calls
    \\trace-import-from-derivation trace-verbose trust-tarballs-from-git-forges
    \\use-case-hack use-cgroups use-registries use-sqlite-wal
    \\use-xdg-base-directories warn-dirty warn-short-path-literals
;

/// The integer settings. `sandbox` and `max-jobs` take a word beside their
/// type and are checked on their own.
const ints =
    \\build-poll-interval connect-timeout cores download-attempts
    \\download-buffer-size download-speed
    \\eval-attrset-update-layer-rhs-threshold eval-profiler-frequency
    \\gc-reserved-space http-connections id-count log-lines max-build-log-size
    \\max-call-depth max-free max-silent-time max-substitution-jobs min-free
    \\min-free-check-interval nar-buffer-size narinfo-cache-meta-ttl
    \\narinfo-cache-negative-ttl narinfo-cache-positive-ttl
    \\stalled-download-timeout start-id tarball-ttl timeout
    \\warn-large-path-threshold
;

/// The integer settings Nix keeps in a 32-bit field, so a larger value is
/// an error there. `max-jobs` is one of them.
const narrow =
    \\build-poll-interval cores download-attempts download-speed
    \\eval-attrset-update-layer-rhs-threshold eval-profiler-frequency id-count
    \\max-call-depth max-jobs max-substitution-jobs narinfo-cache-meta-ttl
    \\narinfo-cache-negative-ttl narinfo-cache-positive-ttl start-id tarball-ttl
;

const aliases = [_][2][]const u8{
    .{ "binary-cache-public-keys", "trusted-public-keys" },
    .{ "binary-caches", "substituters" },
    .{ "binary-caches-parallel-connections", "http-connections" },
    .{ "build-chroot-dirs", "sandbox-paths" },
    .{ "build-compress-log", "compress-build-log" },
    .{ "build-cores", "cores" },
    .{ "build-fallback", "fallback" },
    .{ "build-impersonate-linux-26", "impersonate-linux-26" },
    .{ "build-keep-log", "keep-build-log" },
    .{ "build-max-jobs", "max-jobs" },
    .{ "build-max-log-size", "max-build-log-size" },
    .{ "build-max-silent-time", "max-silent-time" },
    .{ "build-sandbox-paths", "sandbox-paths" },
    .{ "build-timeout", "timeout" },
    .{ "build-use-chroot", "sandbox" },
    .{ "build-use-sandbox", "sandbox" },
    .{ "build-use-substitutes", "substitute" },
    .{ "commit-lockfile-summary", "commit-lock-file-summary" },
    .{ "env-keep-derivations", "keep-env-derivations" },
    .{ "gc-keep-derivations", "keep-derivations" },
    .{ "gc-keep-outputs", "keep-outputs" },
    .{ "substitution-max-jobs", "max-substitution-jobs" },
    .{ "trusted-binary-caches", "trusted-substituters" },
};

const no_debugger = "iets has no debugger";
const no_restricted_mode = "iets has no restricted mode, so every path and URI stays readable";
const no_lint_settings = "iets does not read it; 'iets eval' has the '--lint' flags";

const Unimplemented = struct { name: []const u8, default: []const u8, why: []const u8 };

/// The settings that act in the Nix client and that iets has nothing for:
/// the name, Nix's default, and why. With any other value, whatever set it,
/// classic mode falls back to the real nix (`Config.leftToNix`), and the
/// commands that cannot give one `ignored-setting` warning. The other client
/// settings are applied or hold by construction (`client`).
const unimplemented_ = [_]Unimplemented{
    .{ .name = "abort-on-warn", .default = "false", .why = "builtins.warn never stops an evaluation" },
    .{ .name = "accept-flake-config", .default = "false", .why = ignored.no_nix_config },
    .{ .name = "allow-dirty", .default = "true", .why = "iets evaluates a dirty Git tree as it is" },
    .{ .name = "allow-unsafe-native-code-during-evaluation", .default = "false", .why = "iets has no builtins.exec and no builtins.importNative" },
    .{ .name = "allowed-uris", .default = "", .why = no_restricted_mode },
    .{ .name = "debugger-on-trace", .default = "false", .why = no_debugger },
    .{ .name = "debugger-on-warn", .default = "false", .why = no_debugger },
    .{ .name = "eval-profiler", .default = "disabled", .why = "iets profiles an evaluation with IETS_PROFILE, not with this setting (docs/reference/profile.md)" },
    .{ .name = "eval-system", .default = "", .why = "iets does not read it; builtins.currentSystem is 'system', or the system iets was built for" },
    .{ .name = "ignore-try", .default = "false", .why = no_debugger },
    .{ .name = "impure-env", .default = "", .why = "builtins.getEnv reads the process environment alone" },
    .{ .name = "lint-absolute-path-literals", .default = "ignore", .why = no_lint_settings },
    .{ .name = "lint-short-path-literals", .default = "ignore", .why = no_lint_settings },
    .{ .name = "lint-url-literals", .default = "ignore", .why = no_lint_settings },
    .{ .name = "max-call-depth", .default = "10000", .why = "the call depth limit is fixed at 10000" },
    .{ .name = "log-lines", .default = "25", .why = "iets prints the last 200 lines of a failed build" },
    .{ .name = "plugin-files", .default = "", .why = "iets loads no plugins" },
    .{ .name = "restrict-eval", .default = "false", .why = no_restricted_mode },
    .{ .name = "tarball-ttl", .default = "3600", .why = "iets's fetcher has no such switch" },
    .{ .name = "trace-function-calls", .default = "false", .why = "iets has no function-call trace" },
    .{ .name = "trace-verbose", .default = "false", .why = "builtins.traceVerbose never prints" },
    .{ .name = "trust-tarballs-from-git-forges", .default = "true", .why = "iets's fetcher has no such switch" },
    .{ .name = "warn-short-path-literals", .default = "false", .why = no_lint_settings },
};

/// The `unimplemented_` settings that are no reason to fall back: a flake
/// seldom has a `nixConfig`, and `log-lines` changes no result.
const warn_only = [_][]const u8{ "accept-flake-config", "log-lines" };

/// The other settings that act in the Nix client. iets applies them, or
/// they hold by construction. A known setting outside this list and
/// `unimplemented_` acts in the store, and goes to the daemon
/// (`Config.forwarded`).
const client = [_][]const u8{
    "access-tokens",                                  "allow-dirty-locks",
    "allow-import-from-derivation",                   "bash-prompt",
    "bash-prompt-prefix",                             "bash-prompt-suffix",
    "commit-lock-file-summary",                       "eval-attrset-update-layer-rhs-threshold",
    "eval-cache",                                     "eval-profile-file",
    "eval-profiler-frequency",                        "experimental-features",
    "flake-registry",                                 "json-log-path",
    "nix-path",                                       "nix-shell-always-looks-for-shell-nix",
    "nix-shell-shebang-arguments-relative-to-script", "preallocate-contents",
    "pure-eval",                                      "show-trace",
    "trace-import-from-derivation",                   "use-case-hack",
    "use-registries",                                 "warn-dirty",
};

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

fn inList(list: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, list, " \n");
    while (it.next()) |k| if (std.mem.eql(u8, k, name)) return true;
    return false;
}

/// `$XDG_CONFIG_HOME` or `~/.config` (unix/xdg-dirs.cc:getConfigHome).
pub fn configHome(a: Allocator, e: Env) ![]u8 {
    if (e.nonEmpty("XDG_CONFIG_HOME")) |x| return a.dupe(u8, x);
    return std.fs.path.join(a, &.{ e.nonEmpty("HOME") orelse "/", ".config" });
}

/// `$NIX_CONF_DIR` or the compiled-in `/etc/nix` (globals.cc:nixConfDir).
pub fn confDir(e: Env) []const u8 {
    return e.nonEmpty("NIX_CONF_DIR") orelse "/etc/nix";
}

/// globals.cc:nixUserConfFiles. `$NIX_USER_CONF_FILES` replaces the XDG
/// list wholesale. The list is in precedence order: the *first* entry wins,
/// because loadConfFile applies it last. A set but empty variable is an
/// empty list, so no user file is read at all.
pub fn userConfFiles(a: Allocator, e: Env) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (e.get("NIX_USER_CONF_FILES")) |files| {
        var it = std.mem.splitScalar(u8, files, ':');
        while (it.next()) |f| if (f.len > 0) try out.append(a, try a.dupe(u8, f));
        return out.toOwnedSlice(a);
    }
    const home = if (e.nonEmpty("NIX_CONFIG_HOME")) |h| try a.dupe(u8, h) else try std.fs.path.join(a, &.{ try configHome(a, e), "nix" });
    try out.append(a, try std.fs.path.join(a, &.{ home, "nix.conf" }));
    var dirs = std.mem.splitScalar(u8, e.nonEmpty("XDG_CONFIG_DIRS") orelse "/etc/xdg", ':');
    while (dirs.next()) |d| if (d.len > 0) try out.append(a, try std.fs.path.join(a, &.{ d, "nix/nix.conf" }));
    return out.toOwnedSlice(a);
}

/// `configuration.cc:BaseSetting<bool>::parse`.
pub fn parseBool(name: []const u8, s: []const u8, d: *Diag) Error!bool {
    return parseBoolQuiet(s) orelse d.fail(error.Config, "Boolean setting '{s}' has invalid value '{s}'", .{ name, s });
}

pub fn parseBoolQuiet(s: []const u8) ?bool {
    for ([_][]const u8{ "true", "yes", "1" }) |t| if (std.mem.eql(u8, s, t)) return true;
    for ([_][]const u8{ "false", "no", "0" }) |f| if (std.mem.eql(u8, s, f)) return false;
    return null;
}

/// util.hh:string2IntWithUnitPrefix. A trailing K, M, G or T, in either
/// case, multiplies by 2^10, 2^20, 2^30 or 2^40. `narrow_` is a 32-bit field.
fn parseInt(s: []const u8, narrow_: bool) ?u64 {
    if (s.len == 0) return null;
    var digits = s;
    var mul: u64 = 1;
    switch (std.ascii.toUpper(s[s.len - 1])) {
        'K' => mul = 1 << 10,
        'M' => mul = 1 << 20,
        'G' => mul = 1 << 30,
        'T' => mul = 1 << 40,
        else => |c| if (std.ascii.isAlphabetic(c)) return null,
    }
    if (mul != 1) digits = s[0 .. s.len - 1];
    const t = std.mem.trim(u8, digits, " \t\n\r\x0b\x0c");
    // a leading `+` but not a `-`, as Rust iets reads the number
    const body = if (t.len > 0 and t[0] == '+') t[1..] else t;
    if (body.len == 0) return null;
    for (body) |c| if (!std.ascii.isDigit(c)) return null;
    const n = std.math.mul(u64, std.fmt.parseInt(u64, body, 10) catch return null, mul) catch return null;
    if (narrow_ and n > std.math.maxInt(u32)) return null;
    return n;
}

/// The value check Nix does when a setting is set. `name` is canonical.
pub fn checkValue(name: []const u8, v: []const u8, d: *Diag) Error!void {
    if (inList(bools, name)) {
        _ = try parseBool(name, v, d);
        return;
    }
    // globals.cc:319: the Booleans plus `relaxed`
    if (std.mem.eql(u8, name, "sandbox")) {
        if (!std.mem.eql(u8, v, "relaxed") and parseBoolQuiet(v) == null)
            return d.fail(error.Config, "option 'sandbox' has invalid value '{s}'", .{v});
        return;
    }
    if (std.mem.eql(u8, name, "max-jobs")) {
        if (!std.mem.eql(u8, v, "auto") and parseInt(v, true) == null)
            return d.fail(error.Config, "configuration setting 'max-jobs' should be 'auto' or an integer", .{});
        return;
    }
    if (inList(ints, name) and parseInt(v, inList(narrow, name)) == null)
        return d.fail(error.Config, "setting '{s}' has invalid value '{s}'", .{ name, v });
}

fn isKnown(name: []const u8) bool {
    return inList(known, name);
}

fn alias(n: []const u8) ?[]const u8 {
    for (aliases) |a| if (std.mem.eql(u8, a[0], n)) return a[1];
    return null;
}

/// `name` as the setting it sets: no `extra-`, no alias.
pub fn canonical(name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, name, "extra-")) {
        const b = name["extra-".len..];
        const bare = alias(b) orelse b;
        if (contains(&appendable, bare)) return bare;
    }
    return alias(name) orelse name;
}

/// A setting of Nix that acts in the store, not in the client.
fn actsInStore(name: []const u8) bool {
    return isKnown(name) and !contains(&client, name) and unimplemented(name) == null;
}

fn unimplemented(name: []const u8) ?Unimplemented {
    for (unimplemented_) |u| if (std.mem.eql(u8, u.name, name)) return u;
    return null;
}

/// `a` and `b` are one value: the same Boolean, else the same words.
fn sameValue(a: []const u8, b: []const u8) bool {
    if (parseBoolQuiet(a)) |x| if (parseBoolQuiet(b)) |y| return x == y;
    var ia = std.mem.tokenizeAny(u8, a, " \t\n\r");
    var ib = std.mem.tokenizeAny(u8, b, " \t\n\r");
    while (true) {
        const x = ia.next();
        const y = ib.next();
        if (x == null and y == null) return true;
        if (x == null or y == null or !std.mem.eql(u8, x.?, y.?)) return false;
    }
}

pub const Override = struct { name: []const u8, value: []const u8 };

/// One `ignored-setting` warning for each `--option` that acts in the store
/// and is not in `applied`, for a command line whose store takes none.
pub fn noteUnsent(ig: *ignored.Ignored, overrides: []const Override, applied: []const []const u8, why: []const u8) !void {
    for (overrides) |o| {
        const name = canonical(o.name);
        if (actsInStore(name) and !contains(applied, name)) {
            const raw = try std.fmt.allocPrint(ig.gpa, "setting '{s}' is ignored: {s}", .{ name, why });
            defer ig.gpa.free(raw);
            try ig.note("ignored-setting", name, raw);
        }
    }
}

/// `noteUnsent` for a `grpc://` builder, which has no `SetOptions`.
pub fn noteGrpc(ig: *ignored.Ignored, overrides: []const Override) !void {
    const why = "a grpc:// builder takes no settings; its URL has 'max-builds'";
    try noteUnsent(ig, overrides, &.{ "store", "system" }, why);
    ig.flush();
}

pub const default_system = switch (@import("builtin").cpu.arch) {
    .x86_64 => "x86_64",
    .aarch64 => "aarch64",
    .riscv64 => "riscv64",
    else => @tagName(@import("builtin").cpu.arch),
} ++ "-" ++ switch (@import("builtin").os.tag) {
    .macos => "darwin",
    .windows => "windows",
    else => "linux",
};

/// The Nix settings that apply to this process. Everything it holds is its
/// own, from `gpa`.
pub const Config = struct {
    gpa: Allocator,
    io: Io,
    /// The environment a file is read under: `NIX_PATH` beats `nix-path`.
    env: Env = .{},
    settings: std.StringArrayHashMapUnmanaged([]u8) = .empty,
    /// Set by anything but `$NIX_CONF_DIR/nix.conf`: what a Nix client sends
    /// to the daemon (globals.cc:loadConfFile, `resetOverridden`).
    overridden_: std.StringArrayHashMapUnmanaged(void) = .empty,
    /// List settings that only ever got `extra-` values.
    extra_only: std.StringArrayHashMapUnmanaged(void) = .empty,

    pub fn empty(gpa: Allocator, io: Io, env: Env) Config {
        return .{ .gpa = gpa, .io = io, .env = env };
    }

    pub fn deinit(c: *Config) void {
        for (c.settings.keys(), c.settings.values()) |k, v| {
            c.gpa.free(k);
            c.gpa.free(v);
        }
        c.settings.deinit(c.gpa);
        for ([_]*std.StringArrayHashMapUnmanaged(void){ &c.overridden_, &c.extra_only }) |m| {
            for (m.keys()) |k| c.gpa.free(k);
            m.deinit(c.gpa);
        }
    }

    /// The whole discovery, without the warnings: `$NIX_CONF_DIR/nix.conf`,
    /// then the user files from lowest to highest precedence, then
    /// `$NIX_CONFIG`, then `--option` overrides last (globals.cc:loadConfFile,
    /// common-args.cc:42). `Session.loadNixConf` adds the warnings.
    pub fn read(gpa: Allocator, io: Io, env: Env, overrides: []const Override, d: *Diag) !Config {
        var c: Config = .empty(gpa, io, env);
        errdefer c.deinit();
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        try c.applyFileIfPresent(try std.fs.path.join(a, &.{ confDir(env), "nix.conf" }), d);
        for (c.overridden_.keys()) |k| gpa.free(k);
        c.overridden_.clearRetainingCapacity();
        const files = try userConfFiles(a, env);
        var i = files.len;
        while (i > 0) {
            i -= 1;
            try c.applyFileIfPresent(files[i], d);
        }
        if (env.nonEmpty("NIX_CONFIG")) |text| try c.apply(text, "NIX_CONFIG", d);
        for (overrides) |o| {
            try checkValue(canonical(o.name), o.value, d);
            try c.set(o.name, o.value);
        }
        return c;
    }

    /// An unreadable file is skipped, as loadConfFile's
    /// `catch (SystemError &)` does.
    fn applyFileIfPresent(c: *Config, path: []const u8, d: *Diag) !void {
        const text = Io.Dir.cwd().readFileAlloc(c.io, path, c.gpa, .unlimited) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        defer c.gpa.free(text);
        try c.apply(text, path, d);
    }

    pub fn apply(c: *Config, text: []const u8, origin: []const u8, d: *Diag) !void {
        var entries: std.ArrayList(Entry) = .empty;
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        try parse(arena.allocator(), c.io, text, origin, &entries, d);
        // NIX_PATH, even an empty one, must override the setting
        // (configuration.cc:192)
        const nix_path_set = c.env.get("NIX_PATH") != null;
        for (entries.items) |e| {
            if (nix_path_set and (std.mem.eql(u8, e.name, "nix-path") or std.mem.eql(u8, e.name, "extra-nix-path"))) continue;
            try checkValue(canonical(e.name), e.value, d);
            try c.set(e.name, e.value);
        }
    }

    fn mark(c: *Config, m: *std.StringArrayHashMapUnmanaged(void), name: []const u8) !void {
        if (m.contains(name)) return;
        try m.put(c.gpa, try c.gpa.dupe(u8, name), {});
    }

    fn unmark(c: *Config, m: *std.StringArrayHashMapUnmanaged(void), name: []const u8) void {
        if (m.fetchSwapRemove(name)) |kv| c.gpa.free(kv.key);
    }

    /// configuration.cc:Config::set. An alias is its setting. `extra-<name>`
    /// appends when `<name>` is a list setting; otherwise the pair is kept
    /// under its literal name.
    pub fn set(c: *Config, name: []const u8, value: []const u8) !void {
        const to = canonical(name);
        try c.mark(&c.overridden_, to);
        if (std.mem.startsWith(u8, name, "extra-") and contains(&appendable, to)) {
            if (!c.settings.contains(to)) try c.mark(&c.extra_only, to);
            const gop = try c.settings.getOrPut(c.gpa, to);
            if (!gop.found_existing) {
                gop.key_ptr.* = try c.gpa.dupe(u8, to);
                gop.value_ptr.* = try c.gpa.dupe(u8, value);
                return;
            }
            const old = gop.value_ptr.*;
            const sep: []const u8 = if (old.len > 0 and value.len > 0) " " else "";
            gop.value_ptr.* = try std.mem.concat(c.gpa, u8, &.{ old, sep, value });
            c.gpa.free(old);
            return;
        }
        c.unmark(&c.extra_only, to);
        const v = try c.gpa.dupe(u8, value);
        const gop = try c.settings.getOrPut(c.gpa, to);
        if (gop.found_existing) {
            c.gpa.free(gop.value_ptr.*);
        } else gop.key_ptr.* = c.gpa.dupe(u8, to) catch |e| {
            _ = c.settings.swapRemove(to);
            c.gpa.free(v);
            return e;
        };
        gop.value_ptr.* = v;
    }

    /// The override map of `SetOptions` (remote-store.cc:setOptions): every
    /// store setting the user set outside the system nix.conf, but the ones
    /// `worker::Options` sends as fields. A list that only got `extra-`
    /// values goes as `extra-<name>`, which the daemon appends to its own.
    /// The pairs are in name order, in `a`.
    pub fn forwarded(c: *const Config, a: Allocator) ![]Override {
        // `store` names the daemon this goes to; it is not a setting for it
        const fields = [_][]const u8{ "store", "keep-failed", "keep-going", "fallback", "max-jobs", "max-silent-time", "cores", "substitute" };
        const names = try sortedKeys(a, c.overridden_.keys());
        var out: std.ArrayList(Override) = .empty;
        for (names) |n| {
            if (!actsInStore(n) or contains(&fields, n)) continue;
            const name = if (c.extra_only.contains(n)) try std.fmt.allocPrint(a, "extra-{s}", .{n}) else n;
            try out.append(a, .{ .name = name, .value = c.settings.get(n).? });
        }
        return out.toOwnedSlice(a);
    }

    /// `name` was set outside `$NIX_CONF_DIR/nix.conf`: a user file,
    /// `$NIX_CONFIG` or `--option`.
    pub fn overridden(c: *const Config, name: []const u8) bool {
        return c.overridden_.contains(name);
    }

    pub fn str(c: *const Config, name: []const u8) ?[]const u8 {
        return c.settings.get(name);
    }

    pub fn int(c: *const Config, name: []const u8, d: *Diag) Error!?u64 {
        const s = c.str(name) orelse return null;
        return parseInt(s, inList(narrow, name)) orelse d.fail(error.Config, "setting '{s}' has invalid value '{s}'", .{ name, s });
    }

    pub fn boolean(c: *const Config, name: []const u8, d: *Diag) Error!?bool {
        const s = c.str(name) orelse return null;
        return try parseBool(name, s, d);
    }

    /// A whitespace-separated list setting, iterated. Unset is the empty list.
    pub fn list(c: *const Config, name: []const u8) std.mem.TokenIterator(u8, .any) {
        return std.mem.tokenizeAny(u8, c.str(name) orelse "", " \t\n\r");
    }

    pub fn listHas(c: *const Config, name: []const u8, word: []const u8) bool {
        var it = c.list(name);
        while (it.next()) |w| if (std.mem.eql(u8, w, word)) return true;
        return false;
    }

    /// Whether the `nix-path` entries replace `NIX_PATH`: a file never sets
    /// them beside it, so `--option nix-path` did, and that wins in Nix;
    /// `--option extra-nix-path` adds to it.
    pub fn nixPathReplaces(c: *const Config) bool {
        return c.settings.contains("nix-path") and !c.extra_only.contains("nix-path");
    }

    /// `store`, default `auto` (globals.cc:storeUri).
    pub fn store(c: *const Config) []const u8 {
        return c.str("store") orelse "auto";
    }

    /// `system`, default the build target.
    pub fn system(c: *const Config) []const u8 {
        return c.str("system") orelse default_system;
    }

    /// `max-jobs`, with `auto` resolving to the CPU count. The default is
    /// the CPU count too: that is what this client has always sent.
    pub fn maxJobs(c: *const Config, d: *Diag) Error!u64 {
        const s = c.str("max-jobs") orelse return cpus();
        if (std.mem.eql(u8, s, "auto")) return cpus();
        return (try c.int("max-jobs", d)) orelse cpus();
    }

    /// `cores`, where 0 means "all of them" and is the default this client sends.
    pub fn cores(c: *const Config, d: *Diag) Error!u64 {
        return (try c.int("cores", d)) orelse 0;
    }

    pub fn keepGoing(c: *const Config, d: *Diag) Error!bool {
        return (try c.boolean("keep-going", d)) orelse false;
    }

    pub fn keepFailed(c: *const Config, d: *Diag) Error!bool {
        return (try c.boolean("keep-failed", d)) orelse false;
    }

    /// The first `unimplemented_` setting with a value of its own that is a
    /// reason for classic mode to fall back: the real nix applies it.
    pub fn leftToNix(c: *const Config) ?[]const u8 {
        for (unimplemented_) |u| {
            if (contains(&warn_only, u.name)) continue;
            const v = c.str(u.name) orelse continue;
            if (!sameValue(v, u.default)) return u.name;
        }
        return null;
    }

    /// One note for each setting that has no effect: Nix's own text for a
    /// name it does not know either, the reason for the rest. In name order.
    pub fn noteIgnored(c: *const Config, ig: *ignored.Ignored) !void {
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        for (try sortedKeys(a, c.settings.keys())) |name| {
            const v = c.settings.get(name).?;
            if (!isKnown(name)) {
                try ig.note("unknown-setting", name, try std.fmt.allocPrint(a, "unknown setting '{s}'", .{name}));
            } else if (unimplemented(name)) |u| if (!sameValue(v, u.default)) {
                const raw = try std.fmt.allocPrint(a, "setting '{s}' is ignored: {s}", .{ name, u.why });
                if (std.mem.eql(u8, name, "accept-flake-config"))
                    try ig.noteForNixConfig("ignored-setting", name, raw)
                else
                    try ig.note("ignored-setting", name, raw);
            };
        }
    }
};

fn sortedKeys(a: Allocator, keys: []const []const u8) ![]const []const u8 {
    const out = try a.dupe([]const u8, keys);
    std.mem.sort([]const u8, out, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return out;
}

fn cpus() u64 {
    return std.Thread.getCpuCount() catch 1;
}

/// One `name = value` line, with the file and line it came from so a reader
/// that rejects unknown names can say where the name is.
pub const Entry = struct {
    name: []const u8,
    value: []const u8,
    file: []const u8,
    line: usize,
};

const max_include_depth = 32;

/// configuration.cc:parseConfigFiles. Appends the entries in file order,
/// includes expanded in place; everything lives in `a`.
pub fn parse(a: Allocator, io: Io, text: []const u8, origin: []const u8, out: *std.ArrayList(Entry), d: *Diag) !void {
    return parseInto(a, io, text, origin, out, 0, d);
}

fn parseInto(a: Allocator, io: Io, text: []const u8, origin: []const u8, out: *std.ArrayList(Entry), depth: usize, d: *Diag) !void {
    if (depth > max_include_depth) return d.fail(error.Config, "too many nested includes in {s}", .{origin});
    var lines = std.mem.splitScalar(u8, text, '\n');
    var nr: usize = 0;
    while (lines.next()) |raw| {
        nr += 1;
        const line = if (std.mem.indexOfScalar(u8, raw, '#')) |i| raw[0..i] else raw;
        var tokens: std.ArrayList([]const u8) = .empty;
        // ASCII whitespace: Rust iets splits on Unicode whitespace, which a
        // nix.conf does not hold
        var it = std.mem.tokenizeAny(u8, line, " \t\n\r\x0b\x0c");
        while (it.next()) |t| try tokens.append(a, t);
        const tk = tokens.items;
        if (tk.len == 0) continue;
        if (tk.len < 2) return d.fail(error.Config, "syntax error in configuration line '{s}' in {s}", .{ line, origin });
        const ignore_missing: ?bool = if (std.mem.eql(u8, tk[0], "include")) false else if (std.mem.eql(u8, tk[0], "!include")) true else null;
        if (ignore_missing) |im| {
            if (tk.len != 2) return d.fail(error.Config, "syntax error in configuration line '{s}' in {s}", .{ line, origin });
            const path = if (std.fs.path.isAbsolute(tk[1])) tk[1] else try std.fs.path.join(a, &.{ std.fs.path.dirname(origin) orelse "", tk[1] });
            if (@import("sys/fs.zig").exists(path)) {
                // An existing but unreadable include is ignored, as Nix's
                // `catch (SystemError &)` around the read does.
                if (Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited)) |included| {
                    try parseInto(a, io, included, path, out, depth + 1, d);
                } else |e| if (e == error.OutOfMemory) return error.OutOfMemory;
            } else if (!im) {
                return d.fail(error.Config, "file '{s}' included from '{s}' not found", .{ path, origin });
            }
            continue;
        }
        if (!std.mem.eql(u8, tk[1], "=")) return d.fail(error.Config, "syntax error in configuration line '{s}' in {s}", .{ line, origin });
        try out.append(a, .{
            .name = tk[0],
            .value = try std.mem.join(a, " ", tk[2..]),
            .file = origin,
            .line = nr,
        });
    }
}

const testing = std.testing;

fn fromStr(text: []const u8, origin: []const u8, d: *Diag) !Config {
    var c: Config = .empty(testing.allocator, testing.io, .{});
    errdefer c.deinit();
    try c.apply(text, origin, d);
    return c;
}

const fixture = struct {
    const basic = @embedFile("testdata/conf/basic.conf");
    const extra = @embedFile("testdata/conf/extra.conf");
    const typed = @embedFile("testdata/conf/typed.conf");
    const outer = @embedFile("testdata/conf/outer.conf");
    const middle = @embedFile("testdata/conf/inc/middle.conf");
    const inner = @embedFile("testdata/conf/inc/inner.conf");
};

fn load(text: []const u8) !Config {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    return fromStr(text, "t", &d);
}

test "basic syntax" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var c = try load(fixture.basic);
    defer c.deinit();
    try testing.expectEqualStrings("4", c.str("cores").?);
    try testing.expectEqual(4, try c.cores(&d));
    try testing.expect(try c.keepGoing(&d));
    try testing.expect(!try c.keepFailed(&d));
    try testing.expectEqualStrings("value", c.str("with-comment").?);
    try testing.expectEqualStrings("a b c", c.str("spaced").?);
    try testing.expectEqualStrings("", c.str("empty-value").?);
    // unknown settings are kept
    try testing.expectEqualStrings("kept", c.str("not-a-real-setting").?);
}

test "the setting tables name nix settings" {
    for (aliases) |a| {
        try testing.expect(isKnown(a[1]));
        try testing.expect(!isKnown(a[0]));
    }
    for (unimplemented_) |u| try testing.expect(isKnown(u.name));
    for (client) |n| {
        try testing.expect(isKnown(n));
        try testing.expect(unimplemented(n) == null);
    }
    for (appendable) |n| try testing.expect(isKnown(n));
    for ([_][]const u8{ bools, ints, narrow }) |l| {
        var it = std.mem.tokenizeAny(u8, l, " \n");
        while (it.next()) |n| {
            try testing.expect(isKnown(n));
            try testing.expect(!contains(&appendable, n));
        }
    }
    var b = std.mem.tokenizeAny(u8, bools, " \n");
    while (b.next()) |n| try testing.expect(!inList(ints, n));
    var nw = std.mem.tokenizeAny(u8, narrow, " \n");
    while (nw.next()) |n| try testing.expect(inList(ints, n) or std.mem.eql(u8, n, "max-jobs"));
}

test "an alias is its setting" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var c = try load("build-cores = 3\nextra-binary-caches = https://a\n");
    defer c.deinit();
    try testing.expectEqual(3, try c.cores(&d));
    try testing.expectEqualStrings("https://a", c.str("substituters").?);
    try testing.expectEqualStrings("substituters", canonical("extra-substituters"));
    try testing.expectEqualStrings("extra-cores", canonical("extra-cores"));
    try testing.expectEqualStrings("extra-platforms", canonical("extra-platforms"));
}

test "the daemon gets the store settings set outside the system file" {
    var c = try load("substituters = https://sys\nsandbox = true\n");
    defer c.deinit();
    for (c.overridden_.keys()) |k| testing.allocator.free(k);
    c.overridden_.clearRetainingCapacity();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(0, (try c.forwarded(arena.allocator())).len);
    for ([_][2][]const u8{
        .{ "extra-substituters", "https://me" }, .{ "extra-trusted-public-keys", "k:1" },
        .{ "extra-trusted-public-keys", "k:2" }, .{ "build-timeout", "9" },
        .{ "max-jobs", "1" },                    .{ "store", "ssh-ng://b" },
        .{ "restrict-eval", "true" },            .{ "pure-eval", "true" },
        .{ "lazy-trees", "true" },               .{ "bogus", "1" },
    }) |p| try c.set(p[0], p[1]);
    const f = try c.forwarded(arena.allocator());
    const want = [_][2][]const u8{
        .{ "substituters", "https://sys https://me" },
        .{ "timeout", "9" },
        .{ "extra-trusted-public-keys", "k:1 k:2" },
    };
    try testing.expectEqual(want.len, f.len);
    for (want, f) |w, g| {
        try testing.expectEqualStrings(w[0], g.name);
        try testing.expectEqualStrings(w[1], g.value);
    }
}

test "a setting with no effect is noted" {
    var ig: ignored.Ignored = .init(testing.allocator, testing.io);
    defer ig.deinit();
    var c = try load("no-such-setting-a = 1\nextra-no-such-b = 1\ntrace-verbose = true\n" ++
        "max-call-depth = 10000\nallow-dirty = yes\nsandbox = false\neval-cache = false\n");
    defer c.deinit();
    try c.noteIgnored(&ig);
    try testing.expect(ig.noted("unknown-setting", "no-such-setting-a"));
    try testing.expect(ig.noted("unknown-setting", "extra-no-such-b"));
    try testing.expect(ig.noted("ignored-setting", "trace-verbose"));
    for ([_][]const u8{ "max-call-depth", "allow-dirty", "sandbox", "eval-cache" }) |q| try testing.expect(!ig.noted("ignored-setting", q));
    try noteUnsent(&ig, &.{ .{ .name = "build-use-sandbox", .value = "" }, .{ .name = "keep-outputs", .value = "" }, .{ .name = "system", .value = "" } }, &.{"system"}, "why");
    try noteUnsent(&ig, &.{ .{ .name = "nix-path", .value = "" }, .{ .name = "no-such-setting-c", .value = "" } }, &.{}, "why");
    try testing.expect(ig.noted("ignored-setting", "sandbox"));
    try testing.expect(ig.noted("ignored-setting", "keep-outputs"));
    for ([_][]const u8{ "system", "nix-path", "no-such-setting-c" }) |q| try testing.expect(!ig.noted("ignored-setting", q));
}

test "a classic name leaves an unimplemented setting to nix" {
    const cases = [_]struct { []const u8, ?[]const u8 }{
        .{ "restrict-eval = true\n", "restrict-eval" },
        .{ "max-call-depth = 5\n", "max-call-depth" },
        .{ "restrict-eval = false\nmax-call-depth = 10000\n", null },
        .{ "accept-flake-config = true\nlog-lines = 5\n", null },
        .{ "sandbox = false\neval-cache = false\n", null },
    };
    for (cases) |cs| {
        var c = try load(cs[0]);
        defer c.deinit();
        const got = c.leftToNix();
        if (cs[1]) |w| try testing.expectEqualStrings(w, got.?) else try testing.expect(got == null);
    }
}

test "option nix-path replaces NIX_PATH and extra adds" {
    var c: Config = .empty(testing.allocator, testing.io, .{});
    defer c.deinit();
    try testing.expect(!c.nixPathReplaces());
    try c.set("extra-nix-path", "a=/a");
    try testing.expect(!c.nixPathReplaces());
    try testing.expectEqualStrings("a=/a", c.str("nix-path").?);
    try c.set("nix-path", "b=/b");
    try testing.expect(c.nixPathReplaces());
    try testing.expectEqualStrings("b=/b", c.str("nix-path").?);
}

/// The include fixtures on disk; the caller frees the directory's path.
fn includeTree(t: *testing.TmpDir) ![:0]u8 {
    try t.dir.createDirPath(testing.io, "inc");
    try t.dir.writeFile(testing.io, .{ .sub_path = "outer.conf", .data = fixture.outer });
    try t.dir.writeFile(testing.io, .{ .sub_path = "inc/middle.conf", .data = fixture.middle });
    try t.dir.writeFile(testing.io, .{ .sub_path = "inc/inner.conf", .data = fixture.inner });
    return t.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
}

test "include chain" {
    var t = testing.tmpDir(.{});
    defer t.cleanup();
    const dir = try includeTree(&t);
    defer testing.allocator.free(dir);
    const origin = try std.fs.path.join(testing.allocator, &.{ dir, "outer.conf" });
    defer testing.allocator.free(origin);
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var c = try fromStr(fixture.outer, origin, &d);
    defer c.deinit();
    try testing.expectEqualStrings("1", c.str("from-outer").?);
    try testing.expectEqualStrings("2", c.str("from-middle").?);
    try testing.expectEqualStrings("3", c.str("from-inner").?);
    // The inner file is read where the include sits, so a later line wins.
    try testing.expectEqualStrings("outer-wins", c.str("overridden").?);
}

test "a missing include errors and a bang include does not" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    try testing.expectError(error.Config, fromStr("include nope.conf\n", "/x/x.conf", &d));
    try testing.expect(std.mem.indexOf(u8, d.message(), "included from") != null);
    try testing.expect(std.mem.indexOf(u8, d.message(), "not found") != null);
    var c = try fromStr("!include nope.conf\ncores = 1\n", "/x/x.conf", &d);
    defer c.deinit();
    try testing.expectEqual(1, try c.cores(&d));
}

test "syntax errors" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    for ([_][]const u8{ "cores\n", "cores 4\n", "include a b\n" }) |t| {
        try testing.expectError(error.Config, fromStr(t, "t", &d));
        try testing.expect(std.mem.indexOf(u8, d.message(), "syntax error in configuration line") != null);
    }
}

test "extra appends to list settings only" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var c = try load(fixture.extra);
    defer c.deinit();
    try testing.expectEqualStrings("https://cache.nixos.org/ https://one.example https://two.example", c.str("substituters").?);
    try testing.expectEqualStrings("nix-command flakes", c.str("experimental-features").?);
    // `cores` is not a list, so `extra-cores` stays a setting of its own.
    try testing.expectEqual(2, try c.cores(&d));
    try testing.expectEqualStrings("8", c.str("extra-cores").?);
}

test "typed getters and defaults" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    {
        var c: Config = .empty(testing.allocator, testing.io, .{});
        defer c.deinit();
        try testing.expectEqualStrings("auto", c.store());
        try testing.expectEqual(0, try c.cores(&d));
        try testing.expect(!try c.keepGoing(&d));
        try testing.expect(!try c.keepFailed(&d));
        try testing.expectEqual(cpus(), try c.maxJobs(&d));
        var l = c.list("substituters");
        try testing.expect(l.next() == null);
        try testing.expect(std.mem.endsWith(u8, c.system(), "-linux"));
    }
    var c = try load(fixture.typed);
    defer c.deinit();
    try testing.expectEqualStrings("daemon", c.store());
    try testing.expectEqualStrings("aarch64-linux", c.system());
    try testing.expectEqual(3, try c.maxJobs(&d));
    try testing.expectEqual(7, try c.cores(&d));
    var l = c.list("trusted-public-keys");
    try testing.expectEqualStrings("k1:AAAA=", l.next().?);
    try testing.expectEqualStrings("k2:BBBB=", l.next().?);
}

test "max-jobs auto is the cpu count" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var c = try load("max-jobs = auto\n");
    defer c.deinit();
    try testing.expectEqual(cpus(), try c.maxJobs(&d));
}

// Nix parses a value where it is set, so a bad one stops the run there
// (config-impl.hh:151, configuration.cc:304, globals.cc:319).
test "bad typed values error where they are set" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const cases = [_][2][]const u8{
        .{ "keep-going = maybe\n", "Boolean setting 'keep-going' has invalid value 'maybe'" },
        .{ "cores = many\n", "setting 'cores' has invalid value 'many'" },
        .{ "cores = 4294967296\n", "setting 'cores' has invalid value '4294967296'" },
        .{ "build-cores = -1\n", "setting 'cores' has invalid value '-1'" },
        .{ "sandbox = maybe\n", "option 'sandbox' has invalid value 'maybe'" },
        .{ "max-jobs = 1h\n", "configuration setting 'max-jobs' should be 'auto' or an integer" },
    };
    for (cases) |cs| {
        try testing.expectError(error.Config, fromStr(cs[0], "t", &d));
        try testing.expectEqualStrings(cs[1], d.message());
    }
    // the unit prefix of string2IntWithUnitPrefix, and the words that
    // sandbox and max-jobs take beside their type
    var c = try fromStr("cores = 1K\nmin-free = 2g\nmax-jobs = auto\nsandbox = relaxed\n", "t", &d);
    defer c.deinit();
    try testing.expectEqual(1024, try c.cores(&d));
    try testing.expectEqual(2 << 30, (try c.int("min-free", &d)).?);
    try testing.expectEqual(cpus(), try c.maxJobs(&d));
}

test "bool spellings" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    for ([_]struct { []const u8, bool }{ .{ "true", true }, .{ "yes", true }, .{ "1", true }, .{ "false", false }, .{ "no", false }, .{ "0", false } }) |cs| {
        const text = try std.fmt.allocPrint(testing.allocator, "keep-failed = {s}\n", .{cs[0]});
        defer testing.allocator.free(text);
        var c = try fromStr(text, "t", &d);
        defer c.deinit();
        try testing.expectEqual(cs[1], try c.keepFailed(&d));
    }
}

test "overrides win over files" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var c = try load(fixture.basic);
    defer c.deinit();
    try c.set("cores", "16");
    try testing.expectEqual(16, try c.cores(&d));
}

test "user conf files are in precedence order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var m = try @import("env.zig").fromPairs(testing.allocator, &.{.{ "HOME", "/home/u" }});
    defer m.deinit();
    const files = try userConfFiles(arena.allocator(), .process(&m));
    try testing.expect(files.len > 0);
    try testing.expectEqualStrings("/home/u/.config/nix/nix.conf", files[0]);
    try testing.expectEqualStrings("/etc/xdg/nix/nix.conf", files[1]);
}

test "read layers the files, NIX_CONFIG and the overrides" {
    var t = testing.tmpDir(.{});
    defer t.cleanup();
    try t.dir.createDirPath(testing.io, "sys");
    try t.dir.writeFile(testing.io, .{ .sub_path = "sys/nix.conf", .data = "cores = 1\nsubstituters = https://sys\n" });
    try t.dir.writeFile(testing.io, .{ .sub_path = "user.conf", .data = "cores = 2\n" });
    const dir = try t.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const sys_dir = try std.fs.path.join(testing.allocator, &.{ dir, "sys" });
    defer testing.allocator.free(sys_dir);
    const user = try std.fs.path.join(testing.allocator, &.{ dir, "user.conf" });
    defer testing.allocator.free(user);
    var m = try @import("env.zig").fromPairs(testing.allocator, &.{
        .{ "NIX_CONF_DIR", sys_dir },
        .{ "NIX_USER_CONF_FILES", user },
        .{ "NIX_CONFIG", "keep-going = true" },
    });
    defer m.deinit();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var c = try Config.read(testing.allocator, testing.io, .process(&m), &.{.{ .name = "max-jobs", .value = "3" }}, &d);
    defer c.deinit();
    try testing.expectEqual(2, try c.cores(&d));
    try testing.expect(try c.keepGoing(&d));
    try testing.expectEqual(3, try c.maxJobs(&d));
    try testing.expect(!c.overridden("substituters"));
    try testing.expect(c.overridden("cores") and c.overridden("max-jobs"));
    try testing.expectError(error.Config, Config.read(testing.allocator, testing.io, .process(&m), &.{.{ .name = "cores", .value = "x" }}, &d));
}
