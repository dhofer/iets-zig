//! `iets --help`, `iets COMMAND --help`, `iets help TOPIC`, and the one
//! way a native command reports a bad command line. The texts are Rust
//! iets's byte for byte.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Session = @import("../session.zig").Session;
const Report = @import("../log.zig").Report;
const docs = @import("docs.zig");
const cli = @import("../cli.zig");
const Command = cli.Command;
const Classic = cli.classic.Name;

pub const overview =
    \\usage: iets COMMAND [ARGS...]
    \\
    \\A Nix evaluator, and a client that builds what it evaluates.
    \\
    \\commands:
    \\  eval           evaluate an expression or a file and print the value
    \\  build          evaluate to derivations, one or a set of them, and build them
    \\  search         find packages by regex, like 'nix search'
    \\  diff           print what differs between two derivations
    \\  eval-jobs      print a jobset's derivations as JSON lines (nix-eval-jobs)
    \\  print-dev-env  print the environment of a flake's devShell, for direnv
    \\  prefetch       print the hash of a URL or of a fixed-output derivation
    \\  lint           list the lints and the levels a run would use
    \\  parse          parse Nix files and print or check the syntax tree
    \\  cache          sweep old cache entries, or dump a cache entry's read set
    \\  completion     print the tab-completion script of a shell
    \\  help, version
    \\
    \\classic: 'iets NAME ARGS...' with NAME one of nix-instantiate, nix-build,
    \\  nix-shell, nix-eval-jobs or nix acts like that Nix command,
    \\  and falls back to the real one for the rest ('iets help classic').
    \\
    \\Scripting: JSON, stable exit codes, plumbing ops: 'iets help plumbing'.
    \\
    \\Every command also takes --iets-option NAME VALUE.
    \\Run 'iets COMMAND --help' for the flags of a command.
    \\
;

pub const input =
    \\
    \\common:
    \\  -E, --expr EXPR       evaluate EXPR instead of FILE
    \\  -f, --file FILE       the same as the positional FILE
    \\  -A, --attr PATH       select the attribute PATH; a top-level function is
    \\                        called with the --args at every step of it
    \\  --arg N EXPR, --argstr N STR  call a top-level function with N = EXPR/"STR"
    \\  -I, --include P=PATH  make <P> resolve to PATH
    \\  --impure, --pure-eval  turn pure evaluation off or on
    \\  --workers N           evaluator threads (default: the cores, at most 4)
    \\  --timings             report each phase and the cache on stderr
    \\  --no-tracing-cache    do not use the tracing cache
    \\  --no-ir-cache         do not use the compiled-file cache
    \\  --no-cache            do not use either of them
    \\  --cache-dir DIR       keep the three cache stores in DIR
    \\  --log-format F        internal-json: stderr as Nix JSON records
    \\  --show-trace          put the trace in the JSON error records too
    \\
    \\see: 'iets help commands' for every flag, 'iets help errors'
    \\  for the codes and the records.
    \\
;

pub const eval =
    \\usage: iets eval [FLAGS] (-E EXPR | FILE | FLAKEREF#attr)
    \\
    \\Evaluate an expression, a file or a locked flake and print the value.
    \\
    \\  --strict              evaluate the whole value, not only the top level
    \\  --json                print the value as JSON
    \\  --raw                 print a string as it is, without quotes or newline
    \\  --dump-drvs DIR       write the ATerm of each derivation to DIR
    \\  --lint NAME=LEVEL     set a lint to off, warn or error
    \\  --lint-root DIR       report lint sites under DIR too
    \\  --lint-scope root|all  report sites in the lint roots only, or everywhere
    \\
    \\'iets help lints' is the lint registry.
    \\
;

pub const build =
    \\usage: iets build [FLAGS] (-E EXPR | FILE | FLAKEREF[#ATTR])
    \\       iets build [FLAGS] [--source STOREPATH=LOCAL]... DRV
    \\
    \\Evaluate to derivations, send the closure the builder lacks from memory,
    \\build, and print the output paths ('iets help build-remotely'). A set of
    \\derivations is built whole, each member to its own verdict: 'iets build
    \\.#checks' builds the checks of this system.
    \\
    \\  --builder URL         daemon, unix:///path, ssh-ng://[user@]host or
    \\                        grpc://host:port (default: the builder setting)
    \\  --no-build            upload the closure, do not build
    \\  --dry-run             upload the closure, print what would be built and
    \\                        fetched, do not build; --json: as JSON on stdout
    \\  --json                print {"outcomes"} on stdout, not the paths
    \\  -k, --keep-going      one root: build what a failure does not block
    \\  --out NAME            build the output NAME only (repeatable)
    \\  --fetch-to DIR        copy the outputs from the builder to DIR
    \\  -o, --out-link PATH   bring the outputs into the local store and link
    \\                        them at PATH, PATH-1, ... (GC roots)
    \\  --source SP=LOCAL     with DRV: the local tree of the input source SP
    \\
;

pub const search =
    \\usage: iets search [INSTALLABLE] [FLAGS] REGEX...
    \\
    \\Print the packages whose attribute path, name or description match every
    \\REGEX ('iets help commands'). INSTALLABLE is a flake reference, a path or
    \\<name>; the default is <nixpkgs>. '^' matches every package.
    \\
    \\  -e, --exclude REGEX   hide the packages this matches
    \\  --json                print one object per package, keyed by attribute
    \\  --pretty, --no-pretty  indent the JSON, or do not (default: a terminal)
    \\  -f, --file FILE, --expr EXPR  search a file or an expression instead
    \\  --arg N EXPR, --argstr N STR  call a top-level function with N = EXPR/"STR"
    \\  -I, --include P=PATH  make <P> resolve to PATH
    \\  --impure, --pure-eval  turn pure evaluation off or on
    \\  --workers N           evaluator threads (default: the cores, at most 4)
    \\  --timings             report the index cache on stderr
    \\  --no-tracing-cache    do not use the index, which the tracing cache holds
    \\  --no-ir-cache         do not use the compiled-file cache
    \\  --no-cache            do not use either of them
    \\  --cache-dir DIR       keep the index in DIR
    \\  --log-format F        internal-json: stderr as Nix JSON records
    \\  --show-trace          put the trace in the JSON error records too
    \\
;

pub const diff =
    \\usage: iets diff [FLAGS] A B
    \\       iets diff [FLAGS] -A X -A Y (-E EXPR | FILE | FLAKEREF)
    \\
    \\Print what differs between two derivations, in place of nix-diff: the local
    \\differences first, then the input derivations that differ. A and B are
    \\.drv store paths, flake references or files ('iets help commands').
    \\Exit: 0 they are equal, 1 they differ, 2 trouble.
    \\
    \\  --depth N             levels of input derivations to walk (default 2)
    \\  --all                 walk every level
    \\  --json                print the difference as one JSON object
    \\  --closure             compare the output closures by package and version,
    \\                        as nvd does; the outputs must be in the store
    \\  --builder URL         the store --closure asks (default: daemon)
    \\  -f, --file FILE       the same as the positional FILE
    \\  -I P=PATH, --arg N E, --argstr N S, --option N V, --impure  as for eval
    \\  --log-format F, --show-trace  as for 'iets eval'
    \\
;

pub const eval_jobs =
    \\usage: iets eval-jobs [FLAGS] (-E EXPR | FILE | --flake FLAKEREF[#attr])
    \\
    \\Walk a jobset and print one JSON line per derivation, like nix-eval-jobs
    \\('iets help commands').
    \\
    \\  -E, --expr EXPR       evaluate EXPR instead of FILE
    \\  --flake               the argument is a flake reference
    \\  --arg N EXPR, --argstr N STR  call the top level with N = EXPR/"STR"
    \\  --arg-from-file N F, --arg-from-stdin N  --argstr N from F or stdin
    \\  -I, --include P=PATH  make <P> resolve to PATH
    \\  --impure              turn off the pure evaluation --flake implies
    \\  --workers N           worker processes (default: the cores, at most 4)
    \\  --max-memory-size MB  restart a worker above MB (4096; 0: one process)
    \\  --force-recurse       walk every attribute set, not only marked ones
    \\  --meta, --show-input-drvs  add each job's meta, inputDrvs
    \\  --provenance          add each derivation's source position as pos
    \\  --no-instantiate      do not write the .drv files
    \\  --eval-store URL      the daemon that gets the .drv files (default daemon)
    \\  --gc-roots-dir DIR    add a GC root for each job in DIR
    \\  --reference-lock-file PATH  read PATH instead of the flake's flake.lock
    \\  --check-cache-status  add whether each job is built or substitutable
    \\  --constituents        resolve Hydra aggregate constituents
    \\  --apply EXPR          add the result of EXPR applied to each job
    \\  --select EXPR         walk EXPR applied to the root instead
    \\  --chunks M, --chunk N  evaluate part N (0 to M-1) of M parts of the tree
    \\  --chunk-depth D       split the tree at depth D (default 2)
    \\  --quiet               no summary line on stderr
    \\  --log-format F, --show-trace  as for 'iets eval'
    \\
;

pub const print_dev_env =
    \\usage: iets print-dev-env [FLAGS] [FLAKEREF[#attr]]
    \\
    \\Print the bash that 'nix print-dev-env' prints for a flake's devShell
    \\(default: .), for direnv ('iets help use-with-direnv').
    \\
    \\  --builder URL         the Nix daemon: daemon (default), unix:///path or
    \\                        ssh-ng://[user@]host
    \\  --gc-root PATH        link PATH to the environment and keep it as a GC root
    \\  --json                print what 'nix print-dev-env --json' prints
    \\  --entry-to FILE       write the path of this run's cache entry to FILE,
    \\                        for 'iets cache paths' (see use-with-direnv)
    \\  --workers N, --timings, --cache-dir DIR  as for 'iets eval'
    \\  --no-tracing-cache, --no-ir-cache, --no-cache  as for 'iets eval'
    \\  --log-format F, --show-trace  as for 'iets eval'
    \\
;

pub const lint =
    \\usage: iets lint list [FLAGS] [PATH]
    \\
    \\Print the lint registry with the levels a run from PATH (default: the
    \\current directory) uses, then the scope and its roots ('iets help lints').
    \\
    \\  --lint NAME=LEVEL     set a lint to off, warn or error
    \\  --lint-root DIR       add a lint root
    \\  --lint-scope root|all  report sites in the lint roots only, or everywhere
    \\
;

pub const parse =
    \\usage: iets parse [-q | --json] [--log-format F] FILE...
    \\
    \\Parse each FILE and print its syntax tree; FILE - reads the list from stdin.
    \\
    \\  -q                    print only the parse errors and the totals
    \\  --json                print each tree as one line of JSON
    \\  --log-format F        internal-json: stderr as Nix JSON records
    \\
    \\'iets help syntax-tree' is the schema of the JSON.
    \\
;

pub const cache =
    \\usage: iets cache gc [--ttl DAYS] [--dry-run] [--cache-dir DIR]
    \\       iets cache dump ENTRY
    \\       iets cache paths ENTRY [--json]
    \\
    \\gc removes the cache entries nobody read for DAYS days, and the spark
    \\profile ('sparks' in the cache directory) when it went unread that long;
    \\dump prints the
    \\read set of a tracing-cache entry ('iets help caching').
    \\
    \\paths prints the paths a watcher has to watch for that entry's answer to
    \\go stale, NUL-separated, or --json with the kind of each. A command names
    \\its own entry with --entry-to.
    \\
    \\  --ttl DAYS            the age limit in days
    \\  -n, --dry-run         count what gc would remove, remove nothing
    \\  --cache-dir DIR       sweep DIR instead of the default cache
    \\  --json                one object per path, with its kind
    \\
;

pub const completion =
    \\usage: iets completion bash|zsh|fish|nushell|elvish|powershell
    \\
    \\Print the script that completes 'iets' in that shell, for
    \\'source <(iets completion bash)' in a startup file, or for a file the shell
    \\loads by itself (bash-completion, zsh's fpath, fish's completions). Each
    \\script says in its first lines how its shell loads it.
    \\
    \\The script asks 'iets __complete WORD...' for the candidates, which
    \\prints one 'CANDIDATE<TAB>DESCRIPTION' per line and then ':N', where N
    \\says what the shell adds: 0 files too, 4 nothing.
    \\
;

pub const prefetch =
    \\usage: iets prefetch [FLAGS] URL
    \\       iets prefetch [FLAGS] (-E EXPR | FILE -A ATTR | FLAKEREF#ATTR)
    \\
    \\Print the SRI hash of what URL serves, or the hash a fixed-output
    \\derivation produces, so nothing has to be edited and built to learn it
    \\('iets help commands'). Nothing is added to the store.
    \\
    \\  --unpack              hash the NAR of the unpacked tarball (fetchzip)
    \\  --hash-type ALGO      md5, sha1, sha256 (default) or sha512
    \\  --json                print {"hash", "url"} or {"hash", "drvPath"}
    \\
;

pub const plumbing =
    \\usage: iets plumbing OP [FLAGS] ...
    \\
    \\The machine-first operations the user-facing commands are written against.
    \\Each one writes JSON on stdout ('iets help reference/plumbing').
    \\
    \\operations:
    \\  resolve   an installable becomes derivation roots
    \\  plan      derivation roots become an upload plan
    \\  missing   a plan and a builder become what will be built and fetched
    \\  build     derivation roots are built; outcomes come back
    \\  fetch     a URL or a fixed-output derivation becomes a hash
    \\
    \\Every op that takes roots names them as DRV or DRV!OUT[,OUT], or reads a
    \\previous op's stdout with --roots -. They read the closure from /nix/store
    \\unless --drvs DIR, or a "drvDir" on stdin, names a resolve --dump-drvs
    \\directory; then the derivations come from there.
    \\
    \\usage: iets plumbing resolve [FLAGS] (-E EXPR | FILE | FLAKEREF[#FRAGMENT])
    \\
    \\Print {"attrPaths", "roots"}: the attribute paths that were tried, and
    \\one object per derivation root with "drv", "output" and "attr".
    \\
    \\  --prefixes WHICH      the attribute paths a flake fragment is tried at:
    \\                        package (the default), dev-shell, package-set, or
    \\                        none for the fragment itself
    \\  --want first|all      stop at the first path that is there, or take all
    \\  --walk HOW            how a value becomes roots: context (the default, the
    \\                        derivations its string context and drvPath name),
    \\                        get-drvs (get-drvs.cc, recursing with
    \\                        recurseForDerivations), or to-install
    \\                        (outputSpecified, else meta.outputsToInstall)
    \\  --dump-drvs DIR       write the ATerm of every derivation this evaluation
    \\                        made to DIR, and report DIR as "drvDir", so an op
    \\                        downstream can plan or build a closure that is not
    \\                        in /nix/store
    \\  --no-drvs             report the attribute paths only
    \\
    \\usage: iets plumbing plan [--drvs DIR] [--roots -] DRV...
    \\
    \\Print {"drvs", "sources", "storeDrvs"}: the closure to upload, in
    \\dependency order, references first.
    \\
    \\usage: iets plumbing missing [FLAGS] [--roots -] DRV...
    \\
    \\Print {"willBuild", "willSubstitute", "unknown", "downloadSize",
    \\"narSize"}: what building the roots on the builder would take.
    \\
    \\  --builder URL         where the builds go; the builder setting by default
    \\  --check-cache-status  add "roots": one {"drv", "cacheStatus",
    \\                        "neededBuilds", "neededSubstitutes"} per root
    \\
    \\usage: iets plumbing build [FLAGS] [--roots -] DRV...
    \\
    \\Build the roots and print {"outcomes"}: one {"drv", "success",
    \\"outputs", "reason", "logTail"} each. Exit codes: 'iets help errors'.
    \\
    \\  --builder URL         where the builds go; the builder setting by default
    \\  --out NAME            an output to build besides the roots' own
    \\  --source STOREPATH=LOCAL   upload STOREPATH from a local tree
    \\  --fetch-to DIR        restore every output into DIR
    \\  --gc-root DIR         register each output under DIR on the local daemon,
    \\                        and report the links as "gcRoots"
    \\  --no-build            register the closure and stop
    \\
    \\usage: iets plumbing fetch [FLAGS] URL
    \\       iets plumbing fetch [FLAGS] (-E EXPR | FILE | FLAKEREF[#FRAGMENT])
    \\
    \\Print {"hash", "url"} for what URL serves, or {"hash", "drvPath"} for
    \\the hash a fixed-output derivation produces. Nothing is added to a store.
    \\
    \\  --unpack              hash the NAR of the unpacked tarball (fetchzip)
    \\  --hash-type ALGO      md5, sha1, sha256 (default) or sha512
    \\
;

/// The native commands, in the overview's order.
pub const commands = words(Command);

/// The classic names `iets NAME` answers to.
pub const classic_names = words(Classic);

/// The tags of `E`, which are the words, in declaration order.
pub fn words(comptime E: type) [@typeInfo(E).@"enum".field_names.len][]const u8 {
    const names = @typeInfo(E).@"enum".field_names;
    var out_: [names.len][]const u8 = undefined;
    for (names, &out_) |n, *o| o.* = n;
    return out_;
}

/// The command a help word names: `cache-dump` is the old spelling of
/// `cache dump`.
pub fn commandOf(word: []const u8) ?Command {
    if (std.mem.eql(u8, word, "cache-dump")) return .cache;
    return Command.fromWord(word);
}

/// The help of `cmd` in two parts.
pub fn parts(cmd: Command) [2][]const u8 {
    return switch (cmd) {
        .eval => .{ eval, input },
        .build => .{ build, input },
        .search => .{ search, "" },
        .diff => .{ diff, "" },
        .@"eval-jobs" => .{ eval_jobs, "" },
        .@"print-dev-env" => .{ print_dev_env, "" },
        .prefetch => .{ prefetch, input },
        .plumbing => .{ plumbing, input },
        .lint => .{ lint, "" },
        .parse => .{ parse, "" },
        .cache => .{ cache, "" },
        .completion => .{ completion, "" },
    };
}

/// Help text on stdout; a write that fails is an `io` error. The exit code.
pub fn out(s: *Session, text: []const u8) u8 {
    s.out.writeAll(text) catch return writeFailed(s, text.len);
    return 0;
}

/// The report of a stdout write that failed: the error's text is
/// strerror's, as Rust iets prints it.
pub fn writeFailed(s: *Session, n: usize) u8 {
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "write of {d} bytes: {s}", .{ n, @import("../errors.zig").errnoText(s.out.failure) }) catch "write failed";
    const r: Report = .{ .code = "io", .raw = msg };
    return r.emit(&s.log);
}

/// `iets help [COMMAND | TOPIC]` and `iets COMMAND --help`: the exit code.
/// A name that is both a command and a topic is the command, and the help
/// says where the page is.
pub fn help(s: *Session, cmd: ?[]const u8) u8 {
    var buf: std.Io.Writer.Allocating = .init(s.gpa);
    defer buf.deinit();
    const w = &buf.writer;
    const c = cmd orelse {
        w.writeAll(overview) catch return 1;
        docs.list(w) catch return 1;
        return out(s, buf.written());
    };
    if (commandOf(c)) |k| {
        const p = parts(k);
        w.writeAll(p[0]) catch return 1;
        w.writeAll(p[1]) catch return 1;
        if (docs.find(c)) |page| w.print("\nThe page of the same name: 'iets help {s}/{s}'.\n", .{ page.quadrant, c }) catch return 1;
        return out(s, buf.written());
    }
    if (docs.find(c)) |page| return docs.show(s, page);
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const msg = std.fmt.allocPrint(arena.allocator(), "unknown command or topic '{s}'", .{c}) catch return 1;
    const maybe = suggest(arena.allocator(), c, &help_words) catch null;
    return usage(s, s.log.command, msg, maybe);
}

/// What `iets help WORD` takes: the commands and the topics.
const help_words = commands ++ topics: {
    var t: [docs.pages.len][]const u8 = undefined;
    for (docs.pages, &t) |p, *o| o.* = p.topic;
    break :topics t;
};

/// A flag the help of a command lists.
pub const Flag = struct {
    name: []const u8,
    about: []const u8,
    /// The placeholders of the values it takes: `N`, `EXPR` for `--arg`.
    values: []const []const u8,
};

/// What a word that is no command takes.
const no_command_flags = [_]Flag{
    .{ .name = "--help", .about = "", .values = &.{} },
    .{ .name = "-h", .about = "", .values = &.{} },
    .{ .name = "--version", .about = "", .values = &.{} },
};

/// The flags the help of `word` lists: the words before the description. A
/// word that is no command has `--help`, `-h` and `--version`. The tables are read out of the help at compile time, so
/// the suggestions and the completion follow the help.
pub fn flagTable(word: []const u8) []const Flag {
    return flagsOf(commandOf(word) orelse return &no_command_flags);
}

pub fn flagsOf(cmd: Command) []const Flag {
    return switch (cmd) {
        inline else => |c| comptime tableOf(parts(c)),
    };
}

/// The flag words the help of `word` lists, for a suggestion.
pub fn flagNames(word: []const u8) []const []const u8 {
    const cmd = commandOf(word) orelse return comptime namesOf(&no_command_flags);
    return switch (cmd) {
        inline else => |c| comptime namesOf(tableOf(parts(c))),
    };
}

fn namesOf(comptime table: []const Flag) []const []const u8 {
    var names: [table.len][]const u8 = undefined;
    for (table, &names) |f, *n| n.* = f.name;
    const final = names;
    return &final;
}

/// The flag lines of `texts`: a line that starts `  -`. A short flag takes
/// the values of the long one it is listed with, as in `-f, --file FILE`.
fn tableOf(comptime texts: [2][]const u8) []const Flag {
    @setEvalBranchQuota(1_000_000);
    const trim = " \t\n\r";
    var table: []const Flag = &.{};
    for (texts) |text| {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |l| {
            if (!std.mem.startsWith(u8, l, "  -")) continue;
            const body = l[2..];
            const head, const about = if (std.mem.indexOf(u8, body, "  ")) |k|
                .{ body[0..k], std.mem.trim(u8, body[k + 2 ..], trim) }
            else
                .{ body, "" };
            // the placeholders follow the flag word of its comma-separated
            // alternative; a bare one takes those of the alternative after it
            var alts: []const Flag = &.{};
            var it = std.mem.splitScalar(u8, head, ',');
            while (it.next()) |raw| {
                const alt = std.mem.trim(u8, raw, trim);
                var ws = std.mem.splitScalar(u8, alt, ' ');
                const name = ws.next() orelse continue;
                if (!std.mem.startsWith(u8, name, "-")) continue;
                var values: []const []const u8 = &.{};
                while (ws.next()) |v| {
                    if (std.mem.startsWith(u8, v, "-")) break;
                    values = values ++ .{v};
                }
                alts = alts ++ .{Flag{ .name = name, .about = about, .values = values }};
            }
            for (alts, 0..) |alt, i| {
                var f = alt;
                if (f.values.len == 0 and f.name.len == 2 and i + 1 < alts.len) f.values = alts[i + 1].values;
                table = table ++ .{f};
            }
        }
    }
    return table;
}

/// The commands of the overview with their one-line descriptions.
pub const Summary = struct { name: []const u8, about: []const u8 };

/// The overview's command lines, read out of it at compile time.
pub const summaries: []const Summary = blk: {
    @setEvalBranchQuota(100_000);
    var list: []const Summary = &.{};
    var lines = std.mem.splitScalar(u8, overview, '\n');
    while (lines.next()) |l| if (std.mem.eql(u8, l, "commands:")) break;
    while (lines.next()) |l| {
        if (l.len == 0) break;
        const t = std.mem.trimStart(u8, l, " ");
        const k = std.mem.indexOf(u8, t, "  ") orelse continue;
        list = list ++ .{Summary{ .name = t[0..k], .about = std.mem.trim(u8, t[k + 2 ..], " ") }};
    }
    break :blk list;
};

/// Every word `iets WORD` takes: the native commands, the classic names it
/// answers to, and the two that are not commands.
pub const command_words = commands ++ classic_names ++ [_][]const u8{ "help", "version" };

/// The closest candidate, when it is close enough to be a
/// typo: a third of the candidate, or two edits once the candidate is long
/// enough for two to be a slip rather than another word ('buidl' for 'build').
pub fn suggest(arena: Allocator, word: []const u8, candidates: []const []const u8) Allocator.Error!?[]const u8 {
    var best: ?[]const u8 = null;
    var best_d: usize = 0;
    for (candidates) |c| {
        const dist = try distance(arena, word, c);
        if (!(dist * 3 <= c.len or (dist <= 2 and c.len >= 5))) continue;
        if (best == null or dist < best_d) {
            best = c;
            best_d = dist;
        }
    }
    return best;
}

/// The edit distance of `a` and `b` in code points.
fn distance(arena: Allocator, a: []const u8, b: []const u8) Allocator.Error!usize {
    const ca = try codePoints(arena, a);
    const cb = try codePoints(arena, b);
    const row = try arena.alloc(usize, cb.len + 1);
    for (row, 0..) |*r, j| r.* = j;
    for (ca, 0..) |x, i| {
        var diag = row[0];
        row[0] = i + 1;
        for (cb, 0..) |y, j| {
            const sub = diag + @intFromBool(x != y);
            diag = row[j + 1];
            row[j + 1] = @min(sub, row[j] + 1, diag + 1);
        }
    }
    return row[cb.len];
}

fn codePoints(arena: Allocator, s: []const u8) Allocator.Error![]const u21 {
    var out_: std.ArrayList(u21) = .empty;
    const view = std.unicode.Utf8View.init(s) catch {
        for (s) |c| try out_.append(arena, c);
        return out_.items;
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |c| try out_.append(arena, c);
    return out_.items;
}

/// The report of a bad command line under `cmd` ("iets" before the command
/// word, null in classic mode), emitted; the exit code.
pub fn usage(s: *Session, cmd: ?[]const u8, msg: []const u8, maybe: ?[]const u8) u8 {
    var buf: [512]u8 = undefined;
    const r: Report = .{ .code = "usage", .raw = msg, .hint = usageHint(&buf, cmd, maybe) };
    return r.emit(&s.log);
}

/// `did you mean 'X'?` and where the help is, one per line; null for
/// neither.
pub fn usageHint(buf: []u8, cmd: ?[]const u8, maybe: ?[]const u8) ?[]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    if (maybe) |m| w.print("did you mean '{s}'?", .{m}) catch return null;
    if (cmd) |c| {
        if (maybe != null) w.writeByte('\n') catch return null;
        if (std.mem.eql(u8, c, "iets"))
            w.writeAll("run 'iets --help' for the commands") catch return null
        else
            w.print("run 'iets {s} --help' for the flags", .{c}) catch return null;
    }
    const t = w.buffered();
    return if (t.len == 0) null else t;
}

/// A usage error under the session's command.
pub fn argError(s: *Session, msg: []const u8) u8 {
    return usage(s, s.log.command, msg, null);
}

/// An unknown flag, with the closest flag of the command's help.
pub fn unknownFlag(s: *Session, flag: []const u8) u8 {
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cmd = s.log.command;
    const maybe = if (cmd) |c| suggest(a, flag, flagNames(c)) catch null else null;
    const msg = std.fmt.allocPrint(a, "unknown flag '{s}'", .{flag}) catch return 2;
    return usage(s, cmd, msg, maybe);
}

/// An unknown command word, with the closest command.
pub fn unknownCommand(s: *Session, word: []const u8) u8 {
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const maybe = suggest(a, word, &command_words) catch null;
    const msg = std.fmt.allocPrint(a, "unknown command '{s}'", .{word}) catch return 2;
    return usage(s, s.log.command, msg, maybe);
}

/// `word` is not one of `subs`, the subcommands of this command.
pub fn unknownSubcommand(s: *Session, word: ?[]const u8, subs: []const []const u8) u8 {
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const w = word orelse {
        const msg = std.fmt.allocPrint(a, "missing subcommand: {s}", .{std.mem.join(a, " or ", subs) catch return 2}) catch return 2;
        return usage(s, s.log.command, msg, null);
    };
    const maybe = suggest(a, w, subs) catch null;
    const msg = std.fmt.allocPrint(a, "unknown subcommand '{s}'", .{w}) catch return 2;
    return usage(s, s.log.command, msg, maybe);
}

const testing = std.testing;

test "help fits 80 columns" {
    for (std.meta.tags(Command)) |c| for (parts(c)) |t| {
        var it = std.mem.splitScalar(u8, t, '\n');
        while (it.next()) |l| try testing.expect((std.unicode.utf8CountCodepoints(l) catch l.len) <= 80);
    };
    var it = std.mem.splitScalar(u8, overview, '\n');
    while (it.next()) |l| try testing.expect(l.len <= 80);
}

test "suggestions come from the help" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, []const u8, ?[]const u8 }{
        .{ "eval", "--stirct", "--strict" },
        .{ "build", "--no-ir-cach", "--no-ir-cache" },
        .{ "eval-jobs", "--chunk-dept", "--chunk-depth" },
        .{ "build", "--keep-goin", "--keep-going" },
        .{ "build", "\"A", null },
        .{ "eval", "-x", null },
    };
    for (cases) |c| {
        const got = try suggest(a, c[1], flagNames(c[0]));
        if (c[2]) |w| try testing.expectEqualStrings(w, got.?) else try testing.expectEqual(null, got);
    }
}

test "a mistyped command is suggested" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, ?[]const u8 }{
        .{ "buidl", "build" },         .{ "evl", "eval" },            .{ "serach", "search" },
        .{ "verison", "version" },     .{ "nix-buidl", "nix-build" }, .{ "nix-instantate", "nix-instantiate" },
        .{ "eval-jbos", "eval-jobs" }, .{ "bogus", null },            .{ "x", null },
    };
    for (cases) |c| {
        const got = try suggest(a, c[0], &command_words);
        if (c[1]) |w| try testing.expectEqualStrings(w, got.?) else try testing.expectEqual(null, got);
    }
}

test "usage messages" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("did you mean '--strict'?\nrun 'iets eval --help' for the flags", usageHint(&buf, "eval", "--strict").?);
    try testing.expectEqual(null, usageHint(&buf, null, null));
    try testing.expectEqualStrings("run 'iets --help' for the commands", usageHint(&buf, "iets", null).?);
}

test "the flag table" {
    const t = flagTable("eval");
    var arg: ?Flag = null;
    var f: ?Flag = null;
    for (t) |x| {
        if (std.mem.eql(u8, x.name, "--arg")) arg = x;
        if (std.mem.eql(u8, x.name, "-f")) f = x;
    }
    try testing.expectEqual(2, arg.?.values.len);
    try testing.expectEqualStrings("FILE", f.?.values[0]);
}
