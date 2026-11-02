# iets in Zig

iets in Zig 0.17.0: a faster, idiomatic Zig implementation of iets. It began
as a port of the Rust tree (`../iets`), which stays the test oracle — never
edit it. The port is complete enough that the design is now ours to change.

The reasoning behind each part is in `docs/explanation/`, and what was
tried, kept or dropped in `docs/explanation/history.md`; the reference pages (`docs/reference/`, a link to
`src/cli/docs/`) are embedded in the binary as `iets help`.

## Mission

Compress the Nix stack. A Nix user assembles a working setup from a dozen
helper tools, and most of them exist because Nix lacks one capability or one
good default. iets supplies the capability or the default, so the tool is no
longer needed. Evaluation speed is the first result of this.

The way there is good abstractions and good defaults, not more code. A
feature belongs when it falls out of something the evaluator already owns
(the derivation graph, the read set of a run, the fetchers, the cache stores)
and needs little new code. If a feature needs its own large subsystem, the
abstraction is wrong or the feature belongs elsewhere.

## Goals, in order

1. **Byte-exact parity** with `nix-instantiate --eval --strict` on the
   `.drvPath` of NixOS systems (`scripts/nixos-parity.sh`), and with Nix and
   Rust iets on everything a user or another program can observe: values,
   output, error messages, exit codes, the protocols spoken with the Nix
   daemon and remote builders. The parity scripts in `scripts/` are the
   contract; keep them passing.
2. **Faster than Rust iets and Nix** on `../iets/bench/workloads/nixos-server.nix`.
   Sequential speed first, parallel forcing second. A design change must be
   measured (`scripts/bench.sh`, `IETS_STATS=1`) to be faster or leaner, or
   be clearly more idiomatic at equal speed. Record what was measured, kept
   or dropped, in `docs/explanation/history.md`.
3. **A polished experience out of the box.** The good behaviour is the
   default and needs no flag: errors name the fix, nothing is ignored or
   fails in silence, a build output is not garbage-collected under its user,
   help works offline. The classic command names stay byte-compatible with
   Nix, so polish goes into the native commands, stderr, side effects and
   defaults.
4. **Small, readable, idiomatic Zig.** Modules by phase, one implementation
   of each capability (`docs/explanation/plumbing-and-porcelain.md`).
5. **The fastest client to a remote builder.** Evaluate in memory, ask the
   store what it lacks, send only that in one operation, build.

The internals are ours. Rust's measured designs are a strong starting point,
not a constraint: data layouts, the scheduler, the compiler, the IR and the
module structure may diverge where Zig (comptime, explicit allocators, tagged
unions, `std.Io`) does better. Where an existing design is Rust's, it is
because it measured well; beat it with numbers before replacing it, never
with a simpler substitute that is slower.

## Non-goals

iets is a client with no store of its own. These stay out:

- local store writes, local builds, a builder daemon of our own (builds go
  to a Nix daemon or to nix-grpc-store, somebody else's daemon);
- building during evaluation, so no import from derivation;
- unlocked flakes: registries, `nix flake lock`, locking in memory;
- a git or Mercurial fetcher of our own (`fetchGit` of anything but a local
  working tree, and git/hg flake inputs, run the real nix);
- a REPL, a debugger, a bytecode VM;
- sharing caches with Rust iets: the stores live under `~/.cache/iets-zig`
  (`cachefs.dir_name`), never Rust's `~/.cache/iets`, because their formats
  are ours to change and a format mismatch wipes a store;
- Windows.

An unsupported call fails with the `unsupported` error kind, and a classic
command name then runs the real Nix.

A fetched input lives in the input store, named only by the hash its content
must have, known before the fetch begins
(`docs/explanation/caching.md`). Keep that property: a fetch that cannot
name its result in advance does not go in.

## Layering

A capability is implemented once, below the command line, and a porcelain
command is written against `src/api.zig`. `src/cli/layering.zig` checks it:
no file under `src/cli/` may import a layer below the api outside a
per-file list whose length is asserted. The list may only shrink. When a
command needs something only `cli` has, move it into `api` or the module it
belongs to. Porcelain-side code for presentation, argv compatibility and
interactive flows is fine, however large. A new plumbing operation is
warranted when a program outside iets needs the contract, or a porcelain
command would otherwise reach past the api.

## Layout

- `src/root.zig`: library root. Every module is reachable from here so `zig build test` runs its tests.
- `src/main.zig`: the command line.
- `src/store/`: pure store functions (hashes, store paths, NAR, ATerm).
- `src/syntax/`: interner, lexer, parser, AST.
- `src/compile.zig`, `src/eval/`, `src/runtime/`: compiler, evaluator, values, parallel scheduler.
- `src/builtins/`: one file per family exporting `pub const ops`.

## Changing the evaluator

Fibers migrate between threads and share every value, so these hold in and
around `src/eval/` and `src/runtime/`:

- A helper's evaluator is a copy of the main one (`Evaluator.forkHelper`).
  A new field is copied with it: per-fiber state must be cheap to copy, and
  a table shared across workers goes in `eval/Shared.zig` behind a lock.
- An inline cache on an IR node or a heap object is read and written by
  several threads. Use atomics, and expect stale misses.
- No thread-locals on force paths, the context-switch path or the
  scheduler: a fiber that migrated between two accesses would touch another
  thread's slot.
- A strict list or attribute-set consumer offers its cells to helpers after
  forcing the container (`ev.offerList`, `offerListCoerce`,
  `offerAttrsCoerce`, `offerListDeep`, `offerAttrsDeep`). Leave it out if
  the consumer stops early.
- A forced value is written into a cell only on success, and only on the
  demand path (`ev.par.is_main`). A helper publishes `speculated`, never
  `empty`. Otherwise a cancelled helper could leak a value built from a
  bailed sub-computation, and a cell holding a value would no longer mean
  the program asked for it, which `==` and the printers read.
- A new user-visible effect (a warning, a file, a line on stderr) says what
  a helper does when it reaches it before demand: give up the task
  (`ev.effect`) or hold it back on the thunk (`eval/effects.zig`,
  `deferRun`).
- `Cell.get` loads with acquire and `Cell.set` stores with release. An
  object is fully written before the word that points at it is stored into
  a cell or pushed onto a deque.
- On recursive hot paths, return a plain `Value` with the `.failed`
  sentinel, never `Error!Value` (`docs/explanation/evaluation.md`,
  "The pipeline").

## Builtins

- The helpers are the `pub` `force*`, `mk*`, `call1`/`call2` and
  `coerceToString` functions of `src/eval/Evaluator.zig`; `concatMap` in
  `src/builtins/lists.zig` is a builtin that uses most of them.
- A family is a file under `src/builtins/` exporting `pub const ops`,
  registered in `src/builtins.zig`. Names and arities follow Nix: a `__`
  name is a global and is in `builtins` without the prefix.
- A builtin gets exactly its arity of arguments, none forced, and returns a
  forced value, unless it builds a lazy application on purpose (as `map`,
  `genList`, `mapAttrs` do).
- Each forcing call carries Nix's error context ("while evaluating the
  first argument passed to builtins.foo"), so traces match Nix's.
- A builtin that reads a store path gets the bytes through
  `src/builtins/store_hooks.zig`.
- Update the builtin's row in `docs/reference/builtins.md`.

## Conventions

- `zig build test` must pass; `zig fmt src` clean. Tests live next to the code.
- Errors with a message: take `d: *Diag` (`src/diag.zig`), `return d.fail(error.X, "fmt", .{...})`;
  in the evaluator, `ev.fail(kind, pos, "fmt", .{...})`.
  Messages copy Nix's wording exactly when Nix prints them.
- A doc comment `Mirrors file.cc:function` when a function follows Nix's C++.
- Comments explain why, never restate code.
- Output goes through `*std.Io.Writer`; no `std.debug.print` outside tests.
- Allocators are explicit parameters (`gpa` for general, `arena` for bump).
- Docs follow `docs/README.md`. A reference page that changes with
  behaviour Rust iets does not share needs its divergence mapped in
  `scripts/cli-parity.sh` (`ours`).
- Commit as you go, small and descriptive.

## Zig 0.17 gotchas

- `ArrayList` is unmanaged: `var l: std.ArrayList(T) = .empty; try l.append(gpa, x);`
- Writers are `*std.Io.Writer` (`.fixed(buf)`, `std.Io.Writer.Allocating`); `printHex`, `print`, `writeAll`.
- `main(init: std.process.Init)`; I/O goes through `init.io`.
- No `**` array repeat: use `@as([N]u8, @splat(c))`.
- `std.testing.refAllDeclsRecursive` is gone; use `refAllDecls` per module.
- No declarations between container fields; `for (1..0)` panics; `zig fmt`
  rewrites `@intFromEnum`/`@enumFromInt` to `@backingInt`/`@fromBackingInt`.
- Stdout/stderr: `std.Io.File.Writer.initStreaming`, not `.init` (positional).
- Keep `std.Io.fiber.contextSwitch` in small `noinline` functions: inlined
  deep into `forceThunkRaw`, its `{rsi}` input was never loaded in an
  optimised build, which segfaulted at address 0x8.
