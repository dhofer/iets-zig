# How iets evaluates

iets doesn't walk the syntax tree. It compiles your code to an intermediate
representation first, and it evaluates that lazily, as Nix does, but with
several threads forcing thunks at once. This page explains how both work, and
why the memory layout decides how big a run gets.

Numbers measured on the Rust iets this tree was ported from say so. The
others are this binary's.

## The pipeline

```
source bytes
  -> syntax/lexer.zig / syntax/parser.zig  -> syntax/ast.zig (per file)
  -> compile.zig                           -> eval/ir.zig (scopes resolved, attrpaths merged)
  -> eval/Evaluator.zig                    -> runtime/value.zig Value (lazy graph, forced on demand)
  -> print / json / drvPath
```

The parser keeps raw bindings. Attribute-path merging and scope resolution
happen in the compile step, so the evaluator never searches a scope by
name: every variable is already a `local` slot `(depth, idx)`, or a
`with_var` when no lexical binder exists. IR nodes are 32 bytes, bump
allocated in the worker's arena, and never change once built, so a thunk can
point at one for the whole run. The `local` and `constant` nodes that recur
are shared within a thread.

A file of more than 512 KB of set bindings, such as `hackage-packages.nix`,
is parsed in chunks on idle workers, and a plain set of 2048 bindings or
more is compiled in slices. Every chunk must parse to its end exactly, or the
parse goes on sequentially, so the tree and the errors are always those of
the sequential parse.

### Evaluation as threaded code

`evalRaw` is a frameless dispatch of a handful of instructions that
tail-calls one handler per IR tag. A handler in tail position (`let`,
`with`, `if`, `assert`, a select's default) tail-calls back into it, so the
native stack grows only where the program nests. A constant or a forced
local at a hot call site is read inline, with no call at all.

### Errors on the hot path

An error is one Zig error, `error.EvalFailed`, and the message, kind and
trace live on the evaluator (`Evaluator.failure`). Zig returns an error union
through memory, and copying one at every level of a deep recursion stalled
store forwarding. So the recursive hot paths (`evalRaw`, `applyRaw`,
`forceThunkRaw`) return a plain `Value`, with the sentinel `.failed` and the
error parked on the evaluator. That change alone took `fib(31)` from 0.22 s
to 0.15 s. Builtins are wrapped by a comptime shim that parks their error the
same way, and the parser and compiler return their results in registers
through a small out-of-line shim.

## Thunks

Every argument, attribute value, list element and `let` binding that is
not cheap becomes a thunk. A cheap expression, like a literal or a
variable, reuses the existing value or cell. So a variable that holds a
thunk shares that thunk pointer instead of allocating a second one.

Forcing overwrites the thunk object in place. A thunk is two cells. `code`
holds the IR or the function, and becomes the value. `state` holds the
environment or the argument, and becomes empty. Cells that still point at
the thunk get the value written over them as they are read. That is graph
reduction, and it is why a shared subexpression is evaluated only once.

`mapAttrs` is the case where even two cells were too many. On the outpaths
workload there were 22 million `mapAttrs` thunks and 93 % of them were
never forced. A `mapAttrs` entry has no thunk object at all: a `thunk_map`
value carries a `MapDesc` pointer and an entry index, and one `MapDesc` per
call holds an 8-byte state cell per entry. Sets over 65,536 entries fall
back to ordinary thunks. Measured on Rust iets, that change alone took the
arena from 8,936 MB to 7,981 MB, with the run time inside the noise.

## Values

A `Value` is one 8-byte word with a 3-bit tag in the low bits.

| tag | meaning |
|---|---|
| `int` | 61-bit immediate integer; a larger integer boxes to a heap object |
| `ptr` | pointer to a heap object with a one-byte kind header |
| `thunk`, `thunk_app` | pointer to a two-cell thunk object: IR in an env, or a suspended `f x` |
| `thunk_map` | a `mapAttrs` entry: descriptor pointer plus index, no object |
| `lambda` | pointer to a two-word closure; the tag stands in for the kind byte |
| `imm` | immediates: `null`, `true`, `false` and the evaluator's marks (`blackhole`, `empty`, `speculated`, `failed`) |

The heap kinds behind a `ptr` are `int` (a boxed integer), `float`,
`string` (bytes and context), `path`, `list`, `attrs` (sorted by symbol id),
`attrs_union` (the result of `//`), `primop` and `primop_app`. Environments
(`Env`) are heap objects too.

A `Cell` holds a `Value` and is read with an acquire load and written with a
release store. Environment slots, list elements and attribute values are all
cells, so the sequential path and the parallel path share one shape. There
is no "parallel value" and no "sequential value", only a cell read by one
thread or by four. Cells that a value is read from never hold a blackhole.
Only a thunk's own state cell does.

Attributes are sorted by symbol id, as they are in Nix. Name order, which
`attrNames`, printing, JSON and a derivation environment need, is computed
on demand.

### String context

A string value carries a context: `opaque_path` (a store path), `drv_deep`
(a drv path) or `built` (a drv path and an output name). Context flows
through `+`, through interpolation and through `concatStringsSep`.
`derivationStrict` is where it pays off: it turns the context of every
attribute into the derivation's `inputDrvs` and `inputSrcs`. That is how a
derivation learns its dependencies without you declaring them.

### Frames

Curried lambdas and a lambda's `let` body share one frame, and a partial
application copies the parent's slots when it is called. A lambda whose
parameter is never named gets no frame at all.

## `with` scopes

`with` is the one construct the compiler cannot resolve statically. The
evaluator keeps a chain of `with` scopes in the environment, and a
`with_var` walks that chain innermost first. A lexical binding always wins,
which is why `with_var` is emitted only when no lexical binder exists at
all.

`tryEval` catches `throw` and `assert` failures and nothing else. A lint
raised at level `error` is a different kind, so it escapes, and so does the
`cancelled` failure a bailed helper fiber gets. An error carries a message,
a position and a trace. Each IR node keeps its position, for
`unsafeGetAttrPos`, lambda positions and error messages.

## The `//` operator

When the left side has at least eight entries, `a // b` is not a merged
copy. It is a `Union`: the flat leaves of both sides, at most eight, lowest
priority first. A lookup probes the leaves from the last. An iteration
merges them as it goes. A consumer that needs one contiguous slice asks for
a flat copy, which is made once and cached on the union. Past the leaf
budget, the small leaves after a dominant first one are merged, and the
first is kept shared.

The merge is a loser tree over the leaf heads, so emitting one attribute
costs a few comparisons instead of a scan of every head. Measurement decided
on a union, on Rust iets: on outpaths, `//` copied 5.12 GB, and 80 % of the
results were never iterated at all. The union took the arena from 13,253 MB
to 8,936 MB.

## Shared strings

Each worker keeps a table of context-free string objects by the 64-bit hash
of their bytes, so one text is one object, whatever its size. Growing the
table never reads the bytes again, and a text whose hash collides simply
stays unshared. Every symbol has one cached string object, and each worker
keeps one empty list and one empty set.

On Rust iets's outpaths run, 5.93 million of 7.31 million strings repeated
bytes that were already there. That is 662 MB. Sharing them took the arena
from 7,981 MB to 7,106 MB, for +3 % wall at one worker and −7 % at four.
Keying the table by the bytes instead of by their hash cost 6 % and 12 %, so
the hash stayed.

## ATerm text

A derivation's ATerm text is kept only for the runs that read it back:
instantiation, the tracing cache, `build` and `print-dev-env`. Everything
else handles a derivation with no ATerm, which is also the state of a
derivation read from `/nix/store`. On Rust iets's outpaths run it was
331 MB of heap, and dropping it took peak RSS from 7,680 MB to 7,219 MB.

## Memory

There is one bump arena per worker, in 32 MB chunks advised to be huge
pages, and nothing in it is ever freed. Every value lives until the process
exits, so object layout, not allocation speed, decides peak memory. That is
why the packing on this page (the `mapAttrs` entries, the union, shared
strings, shared frames and dropped ATerms) was worth its complexity.

Everything else comes from `Heap`, the general allocator of release builds:
small blocks on SmpAllocator's path over 64 MB huge-page segments, and
per-class lists for blocks up to 32 MB. glibc malloc's fresh 4 KB pages cost
30k page faults and 50 ms at one worker. Imported sources are read into it
and freed after their compile, and a freed block of 1 MB or more goes back to
the kernel.

On nixos-server the value arena is 541 MB, and peak RSS is 636 MB at one
worker, 733 MB at four and 818 MB at eight (Rust iets: 726, 931 and 1049 MB). What is left is thunks, frames and attribute sets the
program can still reach. No layout change reduces that. Only a collector or
a restart bounds it, which is why `eval-jobs` restarts its worker processes
at `--max-memory-size` instead.

The layout changes measured on Rust iets, before the port:

| | before | after | Nix for scale |
|---|---|---|---|
| server arena | 937 MB | 629 MB | |
| server peak RSS, 1 worker | 988 MB | 659 MB | 690 MB (`nix-instantiate`) |
| outpaths arena | 13,253 MB | 7,106 MB | |
| outpaths peak RSS, 1 worker | 13,495 MB | 7,219 MB | 4.8 GB per nix-eval-jobs worker, restarted at that size |
| outpaths wall, 1 / 4 workers | 32.7 / 15.2 s | 32.5 / 13.5 s | |

A census of the outpaths run after those changes priced several more ideas
and built none of them. They are in
[What was tried and removed](history.md). `zig build -Dstats2=true` and
`IETS_STATS=2` print that census for any run.

## The fiber scheduler

You don't ask for parallel evaluation. It happens on its own: worker threads
force thunks ahead of the demand path and beside it. The parts are:

- A **fiber** is a stackful coroutine with its own stack and its own
  evaluator. It is the unit of blocking, and it moves: a fiber that parks
  on worker A can resume on worker B.
- A **worker** is an OS thread running a drain loop. It owns a bump arena,
  its caches (`Evaluator.Local`), an interner fork, a fiber pool and
  work-stealing deques.
- A **task** is work not yet started, such as forcing a range of list or
  attribute cells. It runs in a pooled fiber.
- The **main fiber** runs the command's own closure. When it returns,
  evaluation is done.

Each helper fiber's evaluator is forked from the main one
(`Evaluator.forkHelper`). Per-fiber state is private. Shared state (the
interner, the file table, the import cache, the derivation table) sits behind
pointers to tables that each have their own lock (`eval/Shared.zig`). A
worker lends its arena and caches to whichever fiber it runs, so N workers
own N arenas, and no fiber ever allocates from an arena another thread is
using. Pointers are global, and cross-arena references are fine, because no
arena is ever freed.

A helper copies the main evaluator's configuration, so every setting must be
in place before evaluation starts. A setting written later would reach the
main fiber only, with silent symptoms: partial output, a cache that no
worker reads, a search path that resolves to nothing. So the configuration is
one `Evaluator.Config`, fixed when the evaluator is made, and nothing writes
it afterwards.

A fiber can run on any worker between two parks, so no force path reads a
thread-local: the compiler may keep a thread-local's address across a park,
and the fiber would then touch another thread's slot. The one thread-local,
the arena a union's flat copy goes to, is read only inside a `noinline`
function that never parks.

### Claiming thunks

The thunk's *state* cell is the synchronisation word. Its states are
disjoint: a payload, a blackhole, or forced (`empty`, or `speculated` when a
helper forced it).

```
payload ──CAS──> BLACKHOLE(claimer, waiters bit) ──store──> EMPTY / SPECULATED
   ^                          │
   └────────── reset ─────────┘   (error, cancel, or an effect in a helper)
```

A force loads the word first, and tries the compare-exchange only on a
payload word. A failed compare-exchange still takes the cache line
exclusive, and most forces hit a thunk another fiber already evaluated:
everything in `lib`, everything in `pkgs`. The plain load keeps those hot
lines shared.

The winner gets the payload back and evaluates. A loser reads the current
word. If it is done, it returns the value. If it is a blackhole holding its
*own* claimer id, that is infinite recursion. The id is per fiber, not per
thread, so it follows a computation that moved. If another fiber holds
it, the loser polls the state for a short while, then parks on a side table
sharded by thunk address, so thunk objects never grow.

### Scaling limits

The default is the number of cores, at most four workers. nixos-server on a
32-core machine (`scripts/bench.sh`, no caches):

| workers | wall |
|---|---|
| 1 | 0.752 s |
| 2 | 0.524 s |
| 4 | 0.406 s |
| 8 | 0.374 s |

Past four workers the gain is small. Useful work averages about 2.6 threads
at four workers: the main fiber mostly waits on derivations, each needing
its inputs', so the run follows one chain of dependencies, and more workers
only add user time. Rust iets measured the same shape on nixos-plasma, where
the wall time stopped falling past six workers.

## Determinism

These properties give the same answer:

- **Forcing is pure.** The value graph is the same whichever fiber forces a
  thunk.
- **A thunk is published at most once per successful evaluation.** A reset
  followed by a re-evaluation yields the same value, because the input did
  not change.
- **Attribute order, list order and derivation hashing do not depend on
  scheduling.** They are decided by symbol ids and by the ATerm, both of
  which are computed from the program.

### Speculation can't change the result

A helper computes ahead of the demand path, so what it computes must leave
no trace the program can read. The places that could show it are closed:

- **The cell.** Only the demand path unboxes a forced cell
  (`Evaluator.forceCell` writes back only when `par.is_main`, and
  `takeCell` is how the demand path takes a helper's result). A helper
  forces the thunk and leaves the cell alone. A cell that holds a value is
  therefore a cell the program asked for, which is what `==` reads for the
  identity of a function and what the printers read for `<CODE>`.
- **The thunk state.** A helper publishes `speculated` where the demand
  path publishes `empty`. Both say "forced"; only the demand path's mark
  makes the value printable. The first demand of a speculated thunk
  upgrades the mark.

The demand path pays for this guarantee. A helper leaves its value inside
the thunk, so the demand path reads the cell, the thunk state and the value,
writes the value into the cell, and writes `empty` over the helper's mark.
Measured on Rust iets, against the same tree with helper unboxing put back,
this cost 3.2 % of the instructions on nixos-server at four workers. At one
worker there is no helper, so it costs nothing.

A lint finding is not a value and is held back instead. One a helper
produced is parked on the innermost thunk the helper was forcing
(`effects.deferRun`). The demand path runs it when it takes that thunk's
value and drops it otherwise. On Rust iets, cancelling the helper, as
`trace` does, was measured at 15 % of the wall for lints, and turning the
fan-out off in the builtins that stop early cost 37 % at four workers, so
neither is the answer.

Effects come out in the order of the sequential run, as in Nix. A thunk's
parked effects keep their order, and a read of another speculated thunk
with effects is one of them. The demand path runs a thunk's effects the
first time it takes its value, directly or through a thunk that read it,
which is where the sequential run forced it. The mark `speculated_fx`
says a thunk has effects, so a read of one without them takes no lock. A
`mapAttrs` entry keeps its value in the set's own cell, where a read does
not take it, so a helper leaves an entry with effects unforced and its
effects go to the thunk that forced it. A deep walk (`forceDeep`) that meets
a cell a helper is busy with does the cells after it as a helper would, then
takes the cells from the busy one on, in order. A thunk that fails keeps its
effects with the thunk that forced it, because a `tryEval` can catch the
error. The effect state lives on the fiber, not on the evaluator: growing
the evaluator moved its hot fields and cost 2 % at one worker.

A `--dump-drvs` file is written where the derivation is made. A parked dump
goes missing while the `drvPath` that names it is returned.

### Failed thunks

Nix evaluates a failed thunk again at every force, and so does iets: a
failure resets the thunk. Under fan-out that turned one failing thunk into
one failing evaluation per task, which Rust iets measured at 20 s and 11 GB
against 0.01 s and 38 MB at one worker. The pool notes the thunk that failed
in a small direct-mapped table (`Pool.noteFailed`). A helper that meets it
drops its task, so only the demand path evaluates it once more and reports.
A run that fails nothing never reads the table.

### Stack limits

The demand fiber gets a 4 GiB stack (`Pool.main_stack`), so a program that
works at one worker is not a crash at four. A helper's stack is 256 MB, and
the force path stops a helper that comes within 1 MB of its guard page. The
helper drops its task in silence and the demand path computes the value, so
the demand fiber reports what Nix reports. A guard page can still be hit,
for example when the compiler recurses over a deeply nested expression
without forcing. Every fiber stack registers its guard page, and a handler
on an alternate signal stack catches the fault, prints Nix's
`stack overflow (possible infinite recursion)` and exits 1. Comparing values
is not a call, so `==` on deep structures is bounded by the stack, not by
`max-call-depth`.

### `trace` and `warn`

`builtins.trace` and `builtins.warn` would break purity in a helper, so
the helper gives them back to the demand path. In a helper fiber they
print nothing: `Evaluator.effect` sets a sticky cancel flag and abandons the
task. Every thunk still open in that fiber is reset, and because a cancelled
force returns an error, no value is written back into any list, attribute
or environment cell. The demand path then evaluates that thunk itself and
prints, exactly once. Journalling the warning and computing on loses it,
because the write-back happens and the demand path never re-evaluates.

Cancel is sticky for the same reason. Once set, every publish the fiber
would still do becomes a reset, so a swallowed error cannot leak a value
built from a bailed sub-computation into a shared thunk.

Trace lines on stderr can come in another order than in a sequential run,
because the demand walk does every unclaimed cell first and parks on busy
ones afterwards. A helper starts at call depth zero, so a program that
fails only by exceeding the maximum call depth sequentially may succeed in
parallel. Both are listed in
[Known divergences from Nix 2.34](../reference/divergences.md#parallel-evaluation).

### Deadlocks

Fan-out can claim the two halves of a cycle on two fibers, which then wait
on each other. Sequential evaluation would have reported infinite recursion
instead. When every worker sleeps, nothing is pending and the main fiber is
not done, the last worker to go to sleep cancels every parked helper fiber.
Each one unwinds, every thunk it claimed is reset, its waiters wake, and the
main fiber re-evaluates the cycle sequentially and reports the error the
sequential path would have reported.

## Speed

`scripts/bench.sh` measures iets against Rust iets and
`nix-instantiate`, and `bench/README.md` keeps a dated comparison. On
nixos-server at one worker, iets takes 0.752 s with no caches and
`nix-instantiate` 2.20 s, and both give the same derivation paths.

Part of the lead comes from the compiled-file cache: a second evaluation
skips the files it already compiled. `--no-ir-cache` turns it off, to
compare the evaluators alone.

More workers finish an evaluation sooner, but they spend instructions to
coordinate. So the gain in wall time depends on the machine more than the
gain in instructions does.

### Search speed

`iets search` caches an index of the packages it finds. On the pinned
nixpkgs, `iets search -I nixpkgs=… hello --json --no-cache` takes 2.1 s, and
its output is Rust iets's byte for byte.

Rust iets measured the rest of the picture on 2026-09-23: wall time, median
of three, on a 16-core EPYC shared with other work. The input was the
pinned nixpkgs, loaded as
`{ legacyPackages.${builtins.currentSystem} = import <pin> {}; }`:

| run | `^hello$` | all packages (`^`) |
|---|---|---|
| Rust iets, no index yet | 6.5 s | 6.8 s |
| Rust iets, index cached | 0.15 s | 0.47 s |
| `nix search`, the same installable | 21 s | 21 s |
| `nix search`, the same tree as a flake, its cache warm | 1.8 s | 2.6 s |
| `nix search`, the same tree as a flake, its cache cold | 37 s | — |

Nix caches a flake installable only, and evaluates `--expr` and `--file`
every time. The `^ --json` output is the same byte for byte on both sides.

## Unproven claims

ThreadSanitizer hasn't been run, and there is no model checker. The
invariants on this page are the argument, and the tests are the evidence: a
concurrent test of the work-stealing deque, the same expressions compared at
one, four and eight workers (`api/concurrent_eval.zig`), the deep-recursion
cases at one and four workers (`scripts/deep-parity.sh`), the lint deferral
case (`scripts/lint-parity.sh`), and the drvPath of nixos-server at every
worker count against Rust iets and `nix-instantiate`
(`scripts/nixos-parity.sh`). Only x86_64 Linux is tested.
