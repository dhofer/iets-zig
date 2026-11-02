# What was tried and removed

You have an idea for the evaluator, the build path or the settings, and
there's a fair chance we already tried it. This page keeps what we built,
what we measured and why it came out again, newest first, so nobody has to
try the same idea a third time. The numbers behind a *current* default live
on that feature's page.

This tree began as a port of Rust iets. The entries under
[Rust iets, before the port](#rust-iets-before-the-port) were measured on
the Rust tree, and they name its files and types; its git history holds the
code. They still hold here, because the port kept those designs. The
entries above that heading were measured on this binary, and this
repository's git history holds them. How the port went, and where the Zig
design differs from Rust's, is on [From Rust iets to Zig](rust-to-zig.md).

## Huge pages that stop at the first failures

*2026-11-02*

On the whole nixpkgs universe (82,544 attributes, 23 GB) iets-zig spent 55 s
in the kernel at 8 workers, against Nix's 8 s. The kernel's counters
(`/proc/vmstat`, before and after a run) named it: 6.7k direct compaction
stalls, 2.2 billion pages scanned for migration, 7.3k of 11.9k huge-page
faults falling back to small pages, and 7.4k direct reclaims. Under
`defrag=madvise`, a fault in a range advised `MADV_HUGEPAGE` compacts memory
synchronously, and once the free 2 MB blocks (some 15 GB here) are used
up, most of those compactions fail. The NixOS workloads never get there:
nixos-server takes all its 351 huge pages with no stall at all.

Measured, interleaved, on the same machine state:

| | outpaths, 8 workers | outpaths, 4 workers | nixos-server, 1 worker |
|---|---|---|---|
| huge pages advised always | 13.5 s, 33 s sys | 17.6 s, 21 s sys | 758 ms |
| no huge pages (`PR_SET_THP_DISABLE`) | 10.3 s, 14 s sys | 15.1 s, 11 s sys | 1053 ms |
| advised until 64 fallbacks | **9.1 s, 10 s sys** | **13.2 s, 7 s sys** | 756 ms |

Kept: the last row (`sys/vm.adviseHuge`). It keeps the 8k huge pages that
came for free and stops after about 140 failures, where the binary before
it went on to 3.6k. The counter is the machine's, so another process's
failures close the gate too; they say the same about free memory. Inlined
into the arena's slow path, the check cost 1.3 % at one worker, on the same
instruction count and the same 351 huge pages, so it is `noinline`. A gate
on free memory at start (Rust iets's, from `/proc/buddyinfo`) was dropped
earlier: it turns huge pages off whenever the page cache holds free memory,
which the cache gives back cheaply.

## A channel tarball, fetched cold

*2026-10-31*

`fetchTree` of nixos-26.05's `nixexprs.tar.zst` (40 MB, 269 MB of tar,
90k members) into an empty input store, read from a local file so the
network is out of it, took 1.68 s. Kept:

- **A zstd decoder of our own** (`fetch/zstd.zig`): std's walks the Huffman
  tree a bit at a time per literal and copies matches a byte at a time,
  1.1 s of the run. Ours decodes in 0.15 s (libzstd 0.12 s). 1.68 s to
  0.70 s.
- **The spool mapped**, not read with a `pread` per member by each of the
  three passes: 0.35 s of system time to 0.11 s. 0.70 s to 0.54 s.
- **Packing workers that pull the biggest file first** from a counter,
  where equal shares left one thread on a 16 MB member: 0.54 s to 0.50 s.
- **`sync_file_range` after each batch**: the pack's `fsync` from 55 ms to
  10 ms. 0.50 s to 0.46 s.
- **The pack index sorted by 8-byte id prefixes** and positions instead of
  whole entries: 0.46 s to 0.45 s.

Dropped: 16 packing threads instead of 8 (the same wall time, more CPU).
The NAR hash looked slow (830 MB/s against std's 2.3 GB/s with SHA-NI),
but the time was the per-member `pread`s in the kernel,
which a user-space profile (`cycles:u`) does not show; time a thread with
`getrusage(RUSAGE_THREAD)` before suspecting the hash.

## Rust shapes, made Zig

*2026-10-31*

With the port done, an audit looked for code that had Rust's shape rather
than Zig's, and the shapes went: traits with one implementation (the
remote log, the dev-shell steps, diff's evaluator), callbacks standing in
for closures on the upload and NAR paths (now a writer to fill and a reader
to drain, which also dropped a disk spool per fetched NAR), `anyerror`
callbacks, `Result`-or-exit-code unions, serde's sorted maps in the log
records, string-typed store paths on the worker protocol, eleven strerror
tables, eight JSON escapers, ten lossy UTF-8 copies, a gpa list copied
into the arena by `filter`, `partition` and `intersectAttrs`, and clap's
per-command parsers (commands and flags are enums switched on).

Some Rust habits were bugs: a ready fiber dropped on a failed append (a
lost wake), a reentrant lock owned by an OS thread while fibers migrate,
effects dropped on allocation failure, two lossy UTF-8 copies unlike
Rust's, stdout failures reported as `WriteFailed`.

On nixos-server the evaluation runs 0.25 to 0.28 % fewer instructions at
one and four workers, with byte-identical output. 200,000 `builtins.trace`
lines print about 35 % faster (370 to 238 ms), from writing each record
straight into one buffer.

Wall time moved within about 2 %, and not from the code that ran: two
builds that differ only in code nixos-server never executes ran the same
9.986 G instructions, 1.9 % apart. Where the linker puts hot code decides
that much. Judge a change by its instructions and by interleaved runs of
both orders, and distrust a wall-time difference under 2 % that the
instruction count does not show.

## Caches of our own

*2026-10-31*

Both binaries kept their stores under `~/.cache/iets`: the tracing cache,
the IR cache, the input store and the roots. Each keyed its entries with its
own build id, so neither read the other's, but they shared the format files,
the locks and the sweep. The formats are this binary's to change, and a
store whose format file doesn't match is wiped, so each binary would wipe
the other's stores. The root is `~/.cache/iets-zig` (`cachefs.dir_name`).
`--cache-dir` and `IETS_CACHE_DIR` still move it.

The tracing cache keys an environment variable's hash with each store's own
secret, so the same run in the two roots records different hashes, and the
parity test compares each binary's entries in its own directory.

## Huge pages, gated and prefaulted

*2026-10-30*

The arena advises every 32 MB chunk to be huge pages and lets it fault in as
it is touched. Three alternatives were measured on nixos-server, run
interleaved, and on the whole-nixpkgs outpaths run (23 GB, with free memory
filled by the page cache):

- **Rust iets's gate**: huge pages only with 1 GB free in blocks of order 9
  and up, read from `/proc/buddyinfo`. With the page cache holding free
  memory, the gate turns huge pages off, and nixos-server at one worker took
  890 ms instead of 757 ms, on 4.6 times the dTLB misses. Reclaiming the
  cache to make huge pages costs less.
- **Rust iets's prefault**: `MADV_POPULATE_WRITE` over each chunk. +1 % at
  one worker, and +3.5 % with 65 MB more RSS at four, from zeroing the
  unused end of each worker's chunk.
- **Prefault a huge page at a time**: 2 MB-aligned chunks, with the bump
  limit at a populated watermark. +1 % on nixos-server, about 2 % less kernel
  time on outpaths at equal THP fallbacks, nothing at four workers.

Under memory pressure the kernel time of a large run follows the count of
THP fallbacks (8.2k fallbacks: 17 s of system time at one worker; 5.2k:
11 s), and the state of memory decides that, not the binary.

## Lazy compilation

*2026-10-30*

Of the 920k IR nodes a nixos-server run makes, 295k are ever evaluated, and
379k sit in the bodies of lambdas that are never called: 37,289 lambdas are
compiled and 6,530 called. Compiling a body on its first call looked like a
large saving.

It isn't. Nix reports an undefined variable, a duplicate attribute or
formal, and the lints for the whole file at import, so a lazy body must
still be walked, resolved and merged eagerly. Making the IR is only about a
tenth of the compile (`irNode`, the arena, shared strings). Laziness would
save some 10 ms and keep every parse tree, about 70 MB, alive.

What the compile spends instead: hash maps (a quarter of it: the merge
index, built only past 16 bindings, and the shared-string table for
literals), `varUses`, and sorting bindings.

## Memory ideas

*2026-10-30*

The arena by object kind is at Rust iets's sizes or below. None of these
paid:

- **Interpolation search in large sets.** Slower than the binary search.
- **Sharing a `select1`'s attribute thunk.** `==` on functions could tell
  the difference.
- **12-byte attribute entries.** An entry is 16 bytes, 4 of them the
  position. At 12 bytes the cells fall off their 8-byte alignment, and
  helper threads could then read them torn.
- **Sorting `sym << 32 | i` keys** for large binding lists in place of the
  pairs. Slower, twice, measured interleaved.
- **A flat table of 16-byte entries for the shared strings.** No change: the
  misses are on the strings, not the table.
- **A background thread that populates arena chunks ahead.** No change, and
  68 MB more RSS: pages zeroed on another core arrive cold.
- **A lookup cache per select site.** Only about 250k of 6.6M lookups are on
  sets of more than 256 entries.
- **Evaluating the arguments of strict builtins in place of a thunk.** 965k
  of the 6.7M thunks are builtin arguments, worth some 2 % after replaying
  errors.

The thunks left, 119 MB, are mostly `apply`, `select1` on a local, `if` and
operators: laziness itself.

## Prefetching and the environment chain

*2026-10-30*

At one worker, nixos-server has 14.6M L2 misses and 2.5M fills from DRAM,
against Rust iets's 20.5M and 3.5M (`l2_cache_req_stat.ic_dc_miss_in_l2`,
`ls_any_fills_from_sys.dram_io_all`). Two kinds of software prefetch were
slower, because the hardware already overlaps them: prefetching a call's
argument nodes and a lambda's body, and write-prefetching ahead of the
arena's bump pointer.

The environment chain walk is the largest single miss site, about 10 % of
the L2 misses. But lookups are mostly at depth 0 to 2 (17.6M lookups, 11M
`up` steps), so a display of ancestors per environment would save at most
4.6M dependent loads, for more environment memory. Not built. The DRAM fills
are mostly first touches: IR read long after its compile, and fresh arena
lines.

## Single-thread ideas

*2026-10-30*

Each was measured slower or no better:

- SIMD skipping of whitespace in the lexer: most runs are one space.
- 64-byte AVX-512 blocks in the byte scanners (`bytes.findAnyPos`,
  `findJsonEscape`): strings are short, and the next delimiter is usually
  within 16 bytes. The build targets the native CPU, so LLVM already uses
  AVX-512 where it sees fit; std's UTF-8 validation and `mem.eql` are
  vectorized, and regex matching is 0.3 % of the run. Byte work as a whole is
  about 9 %, most of it `memcpy` of short strings.
- Replicating the dispatch at each inline evaluation or tail site: the code
  growth costs more than the better prediction gains.
- Omitting frame pointers.
- Prefetching the files of list literals of paths on idle workers: at four
  workers the helpers already compile all but about 100 of the 3570 files,
  through their fan-outs.
- A cache of name orders per set shape for the printers: derivation shapes
  vary too much.
- A larger interner cache (4096 to 16384 entries).
- Inlining `parseIf` into its four call sites.
- Reserving 256 bytes for every concatenation.
- Exiting before teardown.
- Handing the main fiber straight to the worker of the helper whose publish
  woke it. The main fiber parked 30 ms less, but wall time moved by under
  0.5 %: the displaced helper often holds the next thunk.

Measure such changes interleaved, A then B run by run: back-to-back medians
drifted by 20 ms on the development machine.

## Branches on the hot path

*2026-10-30*

Three features first cost the run while they were off:

- **Profiling.** A branch on the profiler in `applyRaw` cost 1.5 % more
  instructions. The call path is one inline function, instantiated twice
  with a comptime flag: the profiled copy keeps its helpers out of line and
  the hot copy inlines them. A run is profiled only when the call limit is 0,
  which the depth check already reads.
- **Lints.** The checks inlined into the hot handlers cost 2 % of the cycles
  at one worker. An off lint is one mask word and a branch, and `x.a or d`
  with a lint on goes out of line, so the select handlers keep their
  frameless tail calls.
- **The effect state of lints.** Kept on the evaluator, it moved the
  evaluator's hot fields and cost 2 % at one worker. It lives on the fiber.

## Error unions on the hot path

*2026-10-30*

Zig 0.17 returns an error union, a plain struct and a tuple through memory;
only a packed integer up to 128 bits, or a pointer, comes back in registers.
The caller then reloads the payload and the error code, stored separately,
as one wide load, and store forwarding stalls, about 5 cycles each. The
parser alone had 48M of them.

The evaluator's hot functions return a plain `Value`, with the sentinel
`.failed` and the error parked on the evaluator. That alone took `fib(31)`
from 0.22 s to 0.15 s. Builtins go through a comptime shim that does the
same, the parser and the compiler return a packed word or a pointer through
an out-of-line shim, and a token is a packed `u128`. Before this and the
threaded dispatch of `evalRaw`, nixos-server took 0.859 s at one worker and
0.487 s at four.

## mimalloc

*2026-10-30*

Rust iets links mimalloc. With glibc malloc, a worker thread got a heap of
fresh 4 KB pages: 30k page faults against Rust iets's 4k at one worker, and
0.18 s of system time against 0.13 s at four. A trial build with mimalloc
compiled from its C source took one worker from 0.965 s to 0.924 s and four
from 0.575 s to 0.538 s.

It was not merged: it adds a C dependency, and a Zig allocator was
chosen instead. `Heap` is SmpAllocator's small path over 64 MB huge-page segments,
with per-class lists for blocks up to 32 MB.

## A thread-local session

*2026-10-30*

Rust iets reaches the run's session (the log, the settings, the events, the
profile) through a thread-local. Here a fiber can move to another thread
between two parks, and the compiler may keep a thread-local's address across
the park, so the fiber would read another thread's slot. The session is a
pointer on the evaluator's configuration and a parameter everywhere else.

## Rust iets, before the port

### No machine-wide settings file

*2026-09-27*

iets read `/etc/iets/iets.toml` (or `$IETS_CONF_DIR/iets.toml`) under the
user file, and the NixOS module had an `iets.settings` option to write it.
It copied the shape of `/etc/nix/nix.conf`. The file, the option and the
variable are gone.

iets is a client. In practice the file held one setting: `builder`, with a
`token-file` in one user's home directory. Every account on the host got
that builder, and root read that user's token. The setting belongs to the
user, so it lives in `~/.config/iets/iets.toml`. Settings come from the
user file, `$IETS_CONFIG`, `--iets-option` and the `IETS_*` variables.

iets ignores a leftover `/etc/iets/iets.toml`, without an error.

### No style lints

*2026-09-27*

The registry had 41 lints. 18 of them came from the parser and the
compiler and were about how code looks: `with`, `with-non-literal`,
`with-nested`, `shadow-builtin`, `shadow-binding`, `unused-binding`,
`unused-formal`, `rec-unused`, `legacy-let`, `deprecated-builtin`,
`overrides`, `unsafe-builtin`, `current-system`, `if-bool-literal`,
`eq-bool`, `manual-inherit`, `empty-let` and `ellipsis-without-bind`. They
went, along with the families `scope` and `style`.

The reason is scope: iets reports what only an evaluator can
know, and has no opinion about how code looks. See
[What iets lints](lint-scope.md). Style is the project's call, and nixpkgs
has its own style for each kind of file. statix and deadnix read the syntax, so copying
their rules into iets told you nothing new.

The removal took 523 lines out of `src/`. The compiler doesn't record a
frame's bindings and uses. On nixos-server with one worker, a run that
compiles every file went from 12.201 G to 12.183 G instructions. A run with
a warm compiled-file cache did not change (9.393 G).

In place of the lints, iets gives you the data. `iets parse --json` prints
the syntax tree with each node's byte span, and a finding is a record with
a span and an edit. A rule is a program you write.

### Late writes to settings

*2026-09-27*

`parallel::guard` was a check in debug builds only. It took a fingerprint
of the fiber template's settings, and after the run it compared that with
the main fiber's settings. A setting written after the clone made a test
fail.

It caught a late write only when a test happened to do one, and it did
nothing in a release build. The bugs that led to it (`--dump-drvs`, the IR
cache, the search path) had one cause: the evaluator had public setting
fields, and `api::configure` wrote them after construction.

`eval::EvalConfig` replaced the guard, `api::configure` and
`Run::configured`. The settings go to a builder, and the evaluator's
setting fields are private, so a late write does not compile. See
[How iets evaluates](evaluation.md).

### No `fast-build`

*2026-09-26*

`iets fast-build` and its classic mode command `nix-fast-build` are gone. They
were 920 lines of another tool's command line: twelve flags it existed to
refuse, its own meaning for `-f`, its own `--option` handling and its own
reject type, beside 510 lines of `iets build`. With them went the result
records behind it (`build/results.rs`: the JSON and JUnit result files,
`--stream-json-lines`, the Actions step summary), the stream that fed it
(`jobs/stream.rs`) and `--retries` in the dispatcher.

What it could do that `build` could not is `build`'s: a set of
derivations is built whole, every root to its own verdict, and `--json`
prints the outcomes. That took about 90 lines. Skipping what is built
needed none: the store already does it.

Running evaluation and builds at the same time did not come along. It
needed a second pipeline: a dispatch thread, a batcher and an incremental
uploader. And it was not worth it. On this repository's 18 checks, the
whole tree evaluates in 0.8 s with the parallel walk and 1.1 s with
`nix-build`'s sequential one, while the builds take minutes. The tracing
cache, which the streaming walk could not use, makes the second run 0.03 s.

### TOML settings

*2026-09-26*

iets's own settings lived in `iets.conf`, in nix.conf's line syntax, while
the lints lived in a TOML `iets.toml`: two formats for one program. The
settings are TOML, in an `iets.toml`. See [Settings](../reference/settings.md).
iets does not read `iets.conf`, and nothing checks for a leftover one: the
NixOS module wrote the new file and removed the old one in the same switch.
`include` and `extra-<name>` went with the format.

### The ATerm buffer

*2026-09-25*

A profile put 9.3 % of a warm run in glibc `malloc` and `free`, even
though the evaluator allocates from an arena. 46 % of that came through
`RawVecInner::finish_grow`. The culprit was the derivation pipeline. Every
derivation is unparsed three times, each into a fresh 4 KiB `String` that
then grows. Inside each unparse, every store path, hash and method name was
built as its own `String` first.

The ATerm goes into one buffer per thread that keeps its capacity. The
buffer is taken out of its slot while in use, because
`hash_derivation_modulo` recurses. `print_store_path`, `print_method_algo`,
`base16_encode_into` and `Hash::write_string_with` append to it directly.
`StorePath::new`,
`make_store_path`, `make_type` and the fixed-output payload size their
buffer once instead of growing it, and `make_type` stopped printing each
reference into a string of its own.

| warm, instructions | before | after | |
|---|---:|---:|---:|
| nixos-server, 1 worker | 9.74 G | 9.39 G | −3.6 % |
| nixos-server, 4 workers | 10.54 G | 10.19 G | −3.4 % |
| nixos-minimal, 1 worker | 7.51 G | 7.22 G | −3.9 % |
| nixos-minimal, 4 workers | 8.12 G | 7.84 G | −3.5 % |

The drvPaths were identical on both workloads and equal to nix 2.34.8. The
drv fixtures round-trip byte for byte. The allocator
bucket went from 780 M instructions to 516 M, and `realloc` fell out of the
profile, so the work went away instead of moving. What is left is
`BTreeSet<StorePath>` clones and the `String` per store path that the
reference sets are made of.

### The loser tree

*2026-09-25*

The first profile of a warm-cache run put `AttrIter::next` at 7.1 %, second
only to `eval` itself and 2.3× the cost of a lookup. The multi-leaf merge
scanned every leaf head twice per attribute: once to pick the minimum, and
once to advance it. So eight leaves cost 16 head checks. A census of one
nixos-server run found where that landed: 8.4 million merge steps, of which
5.1 million came from iterations over six, seven or eight leaves, a few
hundred iterations of 5,000 to 12,000 attributes each.

A loser tree over the heads replaced the scan: one root path per attribute,
three comparisons at eight leaves. Equal syms are ordered by leaf, so the
winner surfaces first and the duplicates behind it are dropped as they
come. `Arena::flat` also merged twice, once through `len()` to size the copy
and once to fill it, which was 1.6 million of the 8.4 million steps. It
sizes the copy at the sum of the leaf lengths, fills it in one pass, and
gives the tail back to the bump pointer.

| warm, instructions | before | after | |
|---|---:|---:|---:|
| nixos-server, 1 worker | 10.03 G | 9.74 G | −2.9 % |
| nixos-server, 4 workers | 10.86 G | 10.54 G | −3.0 % |
| nixos-minimal, 1 worker | 7.75 G | 7.51 G | −3.0 % |
| nixos-minimal, 4 workers | 8.40 G | 8.12 G | −3.2 % |

The drvPaths were identical on both workloads and equal to nix 2.34.8. A fresh profile confirmed the bucket shrank instead of moving.
`AttrIter::next` went from 7.05 % to 4.49 % of a total that is itself 2.9 %
smaller, 707 M instructions to 437 M. `Arena::flat` fell out of the 0.4 %
list.

A randomized test over every leaf count found what the key encoding must
keep. A real head must never tie with the sentinel that fills the tree
while it is built, so keys start at 1, not 0. The tie-break must prefer the
*last* leaf, or `//` returns the wrong side.

### The IR cache in helper fibers

*2026-09-25*

`parallel::try_run` clones the evaluator as the fiber template, and
`api::evaluate` installed the IR cache after that clone, inside the main
fiber. So every helper fiber ran without one. On nixos-server with a warm
cache, a run loaded 2804 entries at one worker and 60 at four. Each helper
parsed and compiled its own imports again.

| nixos-server, warm, instructions | before | after |
|---|---:|---:|
| 1 worker | 10.03 G | 10.03 G |
| 4 workers | 13.05 G | 10.88 G |

That is −16.6 % at four workers, and wall time went from 0.59 s to 0.47 s,
with identical drvPaths. The parallel overhead we had measured as +30 % was
+8 %, and the rest was this bug. A cold four-worker run also wrote the
cache it was meant to fill: 62 entries before, 2807 after. The search path
had the same flaw, so `<nixpkgs>` on a helper fiber resolved against an
empty `__nixPath`. The fix installs both before `try_run`, and
`src/api/run.rs` holds the regression test: the fiber template carries the
configuration, and a warm run reads one entry per file whatever the worker
count.

### `BuildPaths` in nix-grpc-store

*2026-09-20*

nix-grpc-store dropped `BuildPaths` and the `farm` flag in its store info
reply. Every node builds through its scheduler, so a standalone daemon
schedules onto itself. iets followed: one schedule stream per batch, a want
per derivation, and one build call to the assigned worker. The client-side
salting that worked around an unavailable worker went too, and a bounced
build goes back to the scheduler. Until iets followed, every build against
the farm failed with an empty `UNIMPLEMENTED`.

### Build flows

*2026-09-19*

The last build flow outside the dispatcher went. `nix-instantiate`,
`nix-shell` and `print-dev-env` had kept a client flow of their own, 392
lines with its own timings, because folding them into the dispatcher risked
classic stdout. They drive the worker backend through the shared upload,
and the classic byte comparison stayed at 59 of 59.

Cruft that went with it: a compile cache committed under `bench/` (5,287
files, 88 MB, regenerated by a script), one machine's benchmark results, a
workload generator and two workloads nothing ran, a demo script, and the
test fixtures of the removed object store. Kept on purpose: the parse cases
of the vendored Nix language suite, which no script runs, because
`iets parse` dumps its own AST format and not Nix's.

### The `pub(crate)` sweep

*2026-09-19*

We made every `pub` a `pub(crate)`, then restored the real external surface
(the binary, the examples, the tests) one compiler round at a time. After
that, rustc's dead-code lint named 48 unreachable items.

We cut:

- those items: a second string-context parser, ten `nix.conf` getters
  nothing read, provenance and parallel helpers
- creation-time speculation
- three wrappers that had one implementation each

We kept on purpose the test oracle for the spool reader, the `is_empty`
twins clippy requires, and one heap kind whose removal shifts every
discriminant.

We proposed and did *not* cut:

- One flag table for the six argument parsers. It would be about 120 lines
  of `match` against a 100-line dispatcher, and the hand-written usage
  strings would be at risk.
- One varint codec for the three on-disk formats, about 40 net lines.
- Two compression dependencies. Dropping them drops `.tar.bz2` and `.tar.xz`
  flake inputs, which is a behavior change and not a cleanup.

`src/` went from 50,315 to 49,397 lines.

### Creation-time speculation

*2026-09-19*

Helpers evaluated thunks at creation time, behind a flag, off by default.
Fifteen runs of nixos-server: 1.401 s off, 1.544 s at level 1, 1.405 s at
level 3; user time 2.58 s against 2.98 s.

It burned CPU on work nobody asked for, and with no collector the results
stayed in memory. It also needed a third deque lane, a backlog cap and a
creation budget. Removed.

### Scheduling flags

*2026-09-18*

`iets build` got flags for a pool of N connections, upload batches of B
objects on M connections, per-derivation or K-at-a-time build operations,
submitting while the upload runs, critical-path order, and skipping
substitutable paths. They were measured on synthetic graphs of several widths
and depths, on hello and on a nixos-server upload, over a latency shim at 0
and 20 ms, over a unix socket, and against a real host 0.11 s away.

None paid. Per-derivation operations were 7.3× slower on one graph and
10× on another, because each one builds a daemon worker and the connection
is serial. Upload batches of 256 added 0.25 s and of 32 added 0.4 s. A
second uploader added 0.3 s and 9 % daemon CPU.

The reason is that the daemon registers paths one SQLite transaction at a
time, at 0.3–0.5 ms per path, and no client-side cut changes that. Extra
connections paid only as extra `max-jobs`, which the existing options
message already sets. The existing flow stayed; the flags, the shim and the
benchmark script went.

### Single-thread ideas

*2026-09-18*

To keep an idea, wall time had to be better by more than 2 % on one of the two
one-worker workloads, with no regression above 1 % elsewhere.

Kept: the compiled-IR cache.

Rejected:

- **Transient frames on a fiber-local stack.** 20 M of 59 M frames proved
  uncaptured, and it saved 320 MB of RSS on outpaths. But wall time was
  −1.7 % there and +2.5 % on server.
- **An inline cache on attribute selection.** 82 % hits on server, and yet
  +2.2 % to +5.8 % wall, because a miss stores into a shared IR node.
- **One escaped ATerm per derivation.** User time −1 to −3 %, wall −1.2 % on
  outpaths: under the bar, because the derivation path is only about 6 % of
  a run.

### Memory ideas

*2026-09-18*

None of these saved enough to pay for itself. The census came from the
outpaths workload after the four packing changes, with the arena at 7.1 GB:

- **Attribute positions in a side table.** A 16-byte attribute pads back to
  16 without a struct-of-arrays rewrite.
- **Compiling `hackage-packages.nix` lazily.** About 15 MB, but the AST
  stays alive.
- **Flattening `let` frames.** Under 56 MB.
- **A 24-byte string header.** 43 MB.
- **One shared closure for lambdas that capture nothing.** 16 MB.
- **One shared empty attribute set.** 22 MB.

Scoped release without a collector was ruled out too. Failed `tryEval`
scopes held 1.28 MB and not one was free of escapes. Per-unit scopes in
eval-jobs are 0.9 % of the arena, and the rest is the package set the next
unit reuses. Only a collector or a process restart bounds a long run.

### A builder daemon

*2026-09-18*

`iets-builderd`, with its own protocol, and a content-defined-chunking
object store were both removed. The `grpc://` transport is a *client* of
nix-grpc-store, added the same day: somebody else's daemon, with iets as
its client.

### An eval cache

*2026-09-17*

Proposed, measured, not built. The idea: publish "attribute A of source S
evaluates to P" next to the NARs, keyed by the source's NAR hash, the
system and the attribute path, signed with the cache key.

Measured for the 80,000 jobs of the outpaths workload: the index is 4.5 MB
with zstd, and 0.27 MB as a three-week delta. Against that, a lookup
competes with a 1.0 s local evaluation of a NixOS system and a 0.03 s
tracing-cache hit. The first milestone would have been a publisher in
`eval-jobs` and a consumer flag in `build`.

### Parallel tweaks

*2026-09-16*

Each was inside the noise or worse:

- An arena prefault thread (+20 % at sixteen workers).
- No stack trimming, plus prefaulting new stacks.
- A lock-free interner cache in front of the shards, which doubled the
  interner's own self time.
- AST buffer reuse.
- Coercion batches of eight.
- glibc malloc tunables.

Restricting the arena count was far worse.
