# Plumbing and porcelain

If you know git, you know this split. iets has one code path. Every
capability is an operation in the library, with a contract made for programs
first. A plumbing command exposes that operation, with JSON in and JSON out.
The commands you type, the porcelain, use the same operation.

The operation contracts and the JSON shapes are in
[Plumbing operations](../reference/plumbing.md). This page is for people who
change iets: it says what the split requires and how a test enforces it.

## One implementation

**A capability is implemented once, below the command line.** Evaluation,
store access, build dispatch, fetching and flakes live in the library. No
command re-implements one.

**Porcelain may have its own libraries.** Presentation, interactive flows,
Nix argv compatibility, color, tables, progress and UI caches are
porcelain-side code. It may be large, and commands may share it. It is not
a second implementation of a plumbing capability.

**The plumbing must expose what the porcelain needs.** If a porcelain
command reaches past `src/api.zig` into `src/eval/`, `src/store/`,
`src/build/`, `src/remote/`, `src/flake/` or `src/jobs/`, the plumbing has a
gap. Close the gap in the operation layer first.

To decide where something goes, ask one question: **would a plumbing
operation emit this too?** If yes, it is a value, and it belongs below the
command line. If it only ever reaches a terminal, it is presentation, and
it belongs in the porcelain.

### The namespace

The contract is `iets plumbing OP`, a subcommand of the one binary:

- A second binary doubles a large binary and its package, for no gain.
- Classic mode dispatches on `argv[0]`. A second binary complicates the
  symlink set and the exec fallback.
- A hidden prefix hides a contract that must be stable, and a contract
  nobody can find gets copied instead of called.

The top-level help lists `plumbing` as a topic and in the scripting line,
but not each operation: the operations are for programs. `iets plumbing
--help` lists them, and the reference page has the contracts.

## The layering test

**A module boundary, checked by a test.** `src/cli/layering.zig` reads every
`.zig` file under `src/cli/`, drops its comment lines, and fails when an
`@import` resolves into a layer below the api: `build`, `compile`,
`devenv`, `eval`, `flake`, `jobs`, `parallel` (the scheduler,
`src/eval/Pool.zig` and `src/eval/Deque.zig`), `remote`, `store` or `trace`,
outside a per-file allow-list.

**Types.** An evaluator value should not appear in a porcelain signature:
a command that cannot name a value cannot evaluate one. A second list in
the same test tracks `Value` in function signatures, so the check is adopted
file by file.

Both lists have their length locked by a constant, and the test fails on an
entry *wider* than the code needs as well as on a missing one. A reach that
goes can't come back unnoticed, and the lists can't stay ahead of the code.

The reach list holds 19 files and the signature list 7. `flake` is on
neither. `eval` is the layer named most often, because it is the evaluator
type itself. `store` comes next. Rust iets's lists, 17 and 7 entries, are
the target: a Zig entry that Rust's list doesn't have carries a comment that
says so, and each is a gap to close in `src/api.zig`.

**What the test does not ban is the point of it.** A porcelain-side library
can be as large as it needs to be. The render module is presentation, so it
passes. The classic module, the largest under `src/cli`, is Nix argv
compatibility, so it passes too. What matters is whether a file holds a
second implementation of something the operation layer owns. The failure
message says so and names the ways out: close the gap in `src/api.zig`, or
say why the entry belongs on the list and raise the constant.

The test cannot catch everything, so reviewers ask these questions before
they merge a change under `src/cli`:

- Does it import anything below `src/api.zig`? If so, is that presentation,
  compatibility or interaction?
- Does it do, in its own way, something an operation already does?
- Does a new operation have a JSON shape in the reference and an
  end-to-end case?
- Did the allow-list grow?

## New operations

A plumbing operation costs more than the operation it exposes. Flag parsing,
the root vocabulary, the help text and the JSON shaping are the operation;
the capability is already there. So an operation is warranted when a program
outside iets needs the contract, or when a porcelain command would otherwise
reach past `src/api.zig`. `index`, `jobs`, `dev-env`, `drv-show`, `drv-diff`
and `closure-diff` have no such caller, so they are calls.

Before a refactor, say what the second copy is. In Rust iets a shared module
cost 100 to 175 lines before it saved one, and the saving was in the
repeated type, not the repeated line. A move is not a deletion: count only
what no longer exists anywhere.

## Benefits

**One implementation and one name per capability.** `api.installable`
turns a string into derivations, `api.build` dispatches a build, `api.run`
runs an evaluation, `api.fetch` fetches, `api.flake` resolves a flake,
`api.render` says what a value's JSON is.

**A contract.** `iets plumbing resolve | iets plumbing plan` composes
across processes, `missing` is byte-for-byte `build --dry-run --json`, and
every operation's JSON shape is in the reference. `scripts/plumbing-parity.sh`
checks each operation against Rust iets.

`nix-shell` and `print-dev-env` are the exception. They upload a plan and
then speak the worker protocol themselves, to build the derivation's inputs
and read the environment back. Going through the dispatcher would open a
second connection.
