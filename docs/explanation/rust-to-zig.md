# From Rust iets to Zig

You know [Rust iets](https://github.com/numtide/iets), or you're reading
this tree next to it, and you want to know what the Zig version kept, what
it changed and why. This page tells how the port went, where Zig's language
and standard library pushed the design somewhere else, and where the design
moved on its own because a measurement said so. The experiments that came
out again are on [What was tried and removed](history.md); the mechanisms
themselves are on [How iets evaluates](evaluation.md) and the other
explanation pages.

Every number here was measured on iets in Zig unless it says Rust, on a
Ryzen 9 7950X with nixpkgs 26.11pre, evaluating the drvPath of the
`nixos-server` toplevel from Rust's benchmark workloads.

## What carried over

The behaviour is the contract, and it did not move. A value, a line of
output, an error message, an exit code, a byte on the Nix daemon's socket or
a nix-grpc-store call is the same in both binaries, and the same as Nix
where Nix has the feature. Rust iets is the test oracle, and the tree checks
itself against it in several ways:

- Rust's Nix language suite, all 293 cases, through the same harness.
- `iets parse`, as text and as JSON, byte for byte on all 45,605 files of
  nixpkgs and Rust's tests, errors included.
- Rust's own integration tests, copied into a crate of their own and pointed
  at the Zig binary (`scripts/rust-tests.sh`), so a test written for Rust
  passes or fails on Zig.
- A parity script per surface: the help pages, usage errors and shell
  completion, the lints, the tracing cache, TOML, deep recursion, profiles,
  `iets diff`, `iets plumbing`, `eval-jobs`, flakes, and the drvPath of
  NixOS.

Most of the evaluator's design came across unchanged too, because Rust had
measured it, and a design that measured well in Rust measures well in Zig.
The port took these as they were:

- **The value layout.** An 8-byte tagged word holding a 61-bit integer or a
  pointer to a heap object with a one-byte kind header; IR nodes of 32
  bytes; a large `a // b` as a union of at most eight leaves; `mapAttrs`
  entries as map words with no thunk of their own; context-free strings
  shared by content; one cached string per symbol; one frame shared by
  curried lambdas and a lambda's `let` body; no frame for a lambda whose
  parameter is never named.
- **The parallel evaluator.** The thunk claim protocol (a state word that is
  a payload, a blackhole with a waiters bit, `empty` or `speculated`), the
  fiber states, a Chase-Lev deque per worker, the task kinds and their batch
  sizes, the failure table, the in-order deep walk that runs ahead of a busy
  cell, and the rule that a helper never writes a cell and never prints.
- **The caches.** The IR cache's keying, the tracing cache's read set and
  replay, the input store's packs, index and LZ4 blocks. Their bytes began as
  Rust's.
- **The outer structure.** The module split, the library facade that every
  command is written against, and the layering test that keeps the command
  line from reaching past it.

## The port, in order

The port ran from the first commit on 2026-10-29 to the benchmark matrix on
2026-11-02, in five stretches.

### The evaluator core

*2026-10-29, evening.* The first hour laid down the store hashes, the
runtime, the IR compiler, the evaluator and `iets eval`, then the syntax
layer, store paths, NAR, ATerm and `hashDerivationModulo`. The builtins
went in by family, each on its own branch: attributes, lists and math;
derivations; strings and text (regex, JSON, TOML, XML); paths and string
context. The NixOS drvPath parity script came in the same hour, and from
then on every change ran against it.

Rust's memory layout went in next, one shape per commit: unions, `mapAttrs`
words, shared strings, frameless lambdas. Then the first change that Zig
forced rather than Rust suggested: the recursive evaluation paths stopped
returning an error union and started returning a plain word, with a
sentinel for failure (see [Error payloads](#error-payloads)).

Parallel evaluation came last that evening. A first version let helper
threads force cells ahead of the demand path, with a futex for the main
thread to wait on and arena chunks advised as huge pages (that alone took
one worker from 1.22 s to 0.96 s, on 31k page faults instead of 203k). An
hour later it was replaced by a port of Rust's scheduler as it stands:
fiber states, work-stealing lanes and the waiter table. Rust's design had
been measured, and the port's rule was to carry a measured design over
rather than write a simpler one.

At the first status, past midnight, the Zig binary gave the same drvPath as
Rust and Nix at every worker count, passed 278 of the 293 language tests,
and was **slower than Rust**: 1.00 s against 0.95 s at one worker, 0.58 s
against 0.48 s at four.

### Faster than Rust

*2026-10-30, night and morning.* The evaluator crossed over in three steps:

| step | 1 worker | 4 workers |
|---|---|---|
| first parity | 1.00 s | 0.58 s |
| Rust's deep walk, a scratch allocator for the compile, wider scans, an early store query | 0.893 s | 0.511 s |
| a Zig general allocator on huge pages | 0.844 s | 0.474 s |
| 32-byte IR, shared frames (and the IR cache, for warm runs) | 0.849 s | 0.475 s |
| results in registers, threaded dispatch | 0.772 s | 0.443 s |
| smaller wins in the compiler and builtins | 0.758 s | 0.432 s |
| huge files on every worker | **0.752 s** | **0.406 s** |
| *Rust iets, for comparison* | *0.904 s* | *0.484 s* |

The two steps that mattered most were both about how Zig 0.17 compiles a
call (see [Results in registers](#results-in-registers) and
[Threaded dispatch](#threaded-dispatch)). Rust's numbers moved slightly
between snapshots as it was rebuilt; the last column is the one the later
benchmarks use.

### The outer layers

*2026-10-30, afternoon.* With the evaluator ahead, the rest of Rust iets was
ported in parallel, one family per branch and git worktree, each with its
Rust tests, and merged into one tree in about four hours: the fetchers and
the input store, the worker protocol and the nix-grpc-store client, the
lints, the infrastructure (settings, the log, events, profiles, provenance,
the session), builds, `eval-jobs`, dev shells, `iets diff`, the tracing
cache, sources and flakes, the classic Nix command names, the command line
and the library facade, the memory census, TOML, the stack-overflow handler
and the profiler. By the evening every lint case, every language test and
Rust's integration tests passed, apart from the known gaps listed in
[Visible differences](#visible-differences).

### Making it Zig

*2026-10-31.* With nothing left to port, the tree stopped following Rust's
structure:

- The caches moved to a root of their own, `iets-zig`, so the two binaries
  never share a store and the formats are free to change. A store whose
  format file doesn't match is wiped, so sharing would have let each binary
  wipe the other's.
- Rust's explanation pages and rules were carried over and rewritten with
  Zig's names and numbers.
- An audit removed what the port had carried over unused, and then the
  shapes that were Rust's rather than Zig's (the
  [Rust shapes, made Zig](history.md#rust-shapes-made-zig) entry has the
  list): traits with one implementation, callbacks standing in for
  closures, eleven `strerror` tables, eight JSON escapers, ten lossy UTF-8
  copies, and clap's per-command parsers. Commands and flags became enums.
- The comments stopped naming the Rust function each piece came from. A
  comment says why the code does what it does; the Rust tree has its own
  history.

### Fetching and memory

*2026-10-31 to 2026-11-02.* The last work was on things Rust gets from
crates: a zstd decoder of its own, 7 times faster than std's on a channel
tarball; a mapped spool and a better packing order for the input store; and
a gate that stops advising huge pages once the kernel starts failing to
give them, which took the whole nixpkgs universe from 13.5 s to 9.1 s at
eight workers (see [Huge pages](#huge-pages)). The benchmark matrix against
Nix, Determinate Nix, Rust iets and fix closed it (`bench/README.md`).

## Dependencies

Rust iets builds on some 30 crates. iets in Zig has none: `build.zig.zon`
lists no dependencies, and everything else is Zig's standard library or
code in this tree. Each crate's job went somewhere:

| Rust crate | what does the job in Zig |
|---|---|
| `mimalloc` | `Heap`, a general allocator over huge-page segments (see [The general allocator](#the-general-allocator)) |
| `tokio`, `tokio-stream` | OS threads, condition variables and the fiber pool |
| `hyper`, `hyper-util`, `http-body-util` | std's `http.Reader` over a socket read on the caller's thread |
| `rustls`, `tokio-rustls` | std's TLS client for downloads; for gRPC, a copy of std's client extended with ALPN, client certificates and ECDSA suites for TLS 1.2 |
| `rustls-native-certs`, `webpki-roots` | `NIX_SSL_CERT_FILE` or `SSL_CERT_FILE`, else the system's roots, else a bundle embedded in the binary |
| `tonic`, `tonic-prost`, `prost` | an HTTP/2 client with HPACK, gRPC framing, and a protobuf codec generated at compile time from Zig types |
| `zstd` | a zstd encoder and a zstd decoder of this tree, and std's decoder for streamed NAR frames |
| `lz4_flex` | an LZ4 block codec |
| `flate2` | std's inflate |
| `lzma-rust2`, `bzip2` | streaming xz and bzip2 decoders |
| `tar` | a tar reader that feeds the spool |
| `toml` | a port of the `toml` crate's parser |
| `serde_json` | a JSON parser with nlohmann::json's acceptance rules, and writers straight into a `std.Io.Writer` |
| `sha2`, `sha1`, `md-5`, `blake3`, `crc32fast` | `std.crypto` and `std.hash` |
| `memchr` | `@Vector` scans, 16 to 64 bytes at a time |
| `libc`, `rustix`, `getrandom` | `std.posix` and `std.os.linux` |

The price is size: about 96k lines of Zig against Rust's 85k, the
difference being mostly the decoders, the HTTP/2 and TLS work and the tests
that sit next to the code. The gain is that nothing in a hot path is a
black box. The zstd decoder, the xz decoder and the allocator each exist
because std's or the crate's equivalent measured slower on iets's own
workload, and each can be changed when the workload changes.

## Where Zig changed the design

These are the places where a design had to change because Zig is a
different language, or where Zig made a better one cheap.

### Error payloads

A Rust `Result` carries its error value. A Zig error is a bare code, so the
message, the kind and the trace of an evaluation error live on the
evaluator, and the code is one error, `error.EvalFailed`. Outside the
evaluator a function that can fail with a message takes a `Diag` to write
it into. That split turned out to be a gain: an error costs nothing until
someone renders it, and the parallel evaluator can hold a failure back
without carrying a payload through every frame.

On the recursive hot paths even the error code costs too much, for the
reason in the next section. `evalRaw`, `applyRaw` and `forceThunkRaw` return
a plain `Value` with the sentinel `.failed` and park the error on the
evaluator. That change alone took `fib(31)` from 0.22 s to 0.15 s.

### Results in registers

Zig 0.17 returns an error union, a plain struct and a tuple through memory.
Only an integer, a packed struct up to 128 bits (`rax:rdx`) or a pointer
comes back in registers. When a result goes through memory, the caller
reloads the payload and the error code, which were stored separately, as one
wide load, and the CPU's store forwarding stalls on it, about 5 cycles each
time. The parser alone had 48 million of those stalls on nixos-server.

So every hot call returns a register-sized result:

- the evaluator's recursive functions return a `Value`, `.failed` on error;
- every builtin is registered through a comptime shim that inlines it and
  parks its error, so a primop call returns a `Value` too;
- the parser's and the compiler's out-of-line functions go through a small
  inline wrapper over a `noinline` shim that returns a packed word or an
  optional pointer, with the error parked on the parser or compiler, so the
  call sites keep their `try`;
- a token is a packed `u128`.

Rust's `EvalResult<Word>` is two words, a word and a boxed error, and
rustc returns it in registers, so Rust iets never needed any of this. It's
the biggest structural difference between the two evaluators.

### Threaded dispatch

Rust iets evaluates with a recursive `match` over the IR enum. Zig has
guaranteed tail calls (`@call(.always_tail, ...)`), and the evaluator uses
them: `evalRaw` is a frameless dispatch of about seven instructions that
tail-calls one `noinline` handler per IR tag, and a handler in tail
position (`let`, `with`, `if`, `assert`, a select's default) tail-calls back
into the dispatch. The native stack grows only where the program nests.
The handlers must all be `noinline`,
because inlining is part of a function's type and a tail call needs equal
types. A constant or a forced local at a hot call site is read inline,
without any call.

Register returns and threaded dispatch together took one worker from
0.849 s to 0.772 s.

### Compile time instead of features and runtime tables

Several things Rust does with cargo features or at startup happen at
compile time in Zig:

- **The memory census** is a cargo feature in Rust. In Zig every hook sits
  behind a comptime flag (`-Dstats2=true`), and the census marks are `void`
  fields in header padding when it is off, so the default build is the
  same machine code. The ReleaseFast symbols differ only in the cold
  printing.
- **The profiler** costs nothing when off. The apply path is one inline
  function instantiated twice, with a comptime `profiled` flag: the
  profiled copy calls its helpers out of line and pushes Rust's frames, the
  hot copy inlines them. A runtime branch on profiling in the hot path
  measured 1.5 % more instructions.
- **The flag tables** of the command line are read out of the help texts at
  compile time, where Rust parses them at startup. The suggestions and the
  completion follow the help because they are made from it.
- **The protobuf codec** for nix-grpc-store is generated from Zig struct
  types at compile time, where Rust runs `prost-build` over `.proto` files.

### Explicit allocators

Every allocation in Zig names its allocator, which made the evaluator's
memory easier to see and to split by lifetime:

- Values go to the worker's arena, 32 MB chunks advised to be huge pages,
  never freed during a run, as in Rust.
- Temporaries dropped together use `Scratch`, a bump allocator with one
  owner. std's `ArenaAllocator` is thread-safe in 0.17 and pays an atomic
  per allocation, which showed up on the derivation path.
- Everything else uses `Heap` in release builds and `DebugAllocator` in
  debug builds, so every test run checks for leaks and double frees.

### Fibers

Rust iets has its own context switch, which saves the callee-saved
registers and swaps stack pointers. Zig 0.17 has one in std
(`std.Io.fiber.contextSwitch`), and the fiber pool uses it. It is called
from small `noinline` functions only: inlined deep into `forceThunkRaw`, its
`rsi` input was never loaded in an optimized build, which segfaulted at
address 0x8.

### No thread-locals

Rust iets reaches the run's session (the log, the settings, the events)
through `Session::current()`, a thread-local. Fibers migrate between
threads, and LLVM may cache a thread-local's address across a park, so a
fiber that moved would touch another thread's slot. In Zig the session is
a pointer on the evaluator's configuration and a parameter everywhere else,
and no force path, context switch or scheduler path reads a thread-local.
The one exception is the union flattener, a `noinline` function that never
parks.

### Unwinding and stack overflow

Rust exits from deep inside an argument parse by unwinding. Zig has no
unwinding, so the argument parser collects the message and the command
reports it once, with Rust's "did you mean" and exit code 2.

A stack overflow ends as in Rust, with the same message, but by a different
route. Each pool thread installs a signal handler on an alternate stack,
and every fiber stack registers its guard page with it, so an overflow on a
fiber prints `error: stack overflow (possible infinite recursion)` and exits
1. A one-worker run evaluates on a 4 GiB thread, where Rust's runtime prints
`thread '<unknown>' (TID) has overflowed its stack` and aborts; that thread
registers its guard page so Zig prints the same. Comparing values is not a
call in either tree, so `==` on deep structures is bounded by the stack
and not by `max-call-depth`.

### Debug builds

Zig's self-hosted backend, which builds Debug by default, has no tail
calls, so a Debug build's dispatch makes plain calls. A Debug build also
gives every inlined call its own stack slots, and the deep-nesting test of
the parser overflowed its 1 GB stack; the parser's hot helpers inline only
in optimized builds. The register-return shims call their bodies directly
in Debug, so the nesting limit still sees one frame per level.

## Where the design moved on

These changes weren't forced by the language. Each one measured faster or
leaner on iets's workloads than Rust's design, and each replaced Rust's
only after it did.

### The general allocator

Rust iets links mimalloc. iets in Zig has `Heap`: SmpAllocator's small-block
path over 64 MB huge-page segments, with per-class global lists for blocks
up to 32 MB. A freed block keeps its address range, and one of 1 MB or more
gives its pages back to the kernel. glibc's malloc, the first stand-in, cost
30k page faults and 50 ms at one worker. A trial build with mimalloc
compiled from its C source took one worker from 0.965 s to 0.924 s, but it
added a C dependency, so a Zig allocator was written instead
([mimalloc](history.md#mimalloc)).

### Huge pages

Rust iets turns huge pages on when `/proc/buddyinfo` shows 1 GB free in
2 MB blocks, and prefaults each arena chunk. Both measured worse in Zig.
With the page cache holding free memory, Rust's check turns huge pages off,
and one worker took 890 ms instead of 757 ms, on 4.6 times the TLB misses;
prefaulting cost 1 % at one worker and 3.5 % plus 65 MB at four, from
zeroing every worker's unused chunk end.

iets in Zig advises huge pages always and stops once the kernel has failed
64 huge-page faults (`thp_fault_fallback` in `/proc/vmstat`). A NixOS
evaluation never reaches that and keeps every huge page; without them,
nixos-server takes 1053 ms instead of 758 ms. The whole nixpkgs universe
(23 GB) outgrows the free 2 MB blocks, and there the gate took eight
workers from 13.5 s and 33 s of kernel time to 9.1 s and 10 s
([Huge pages that stop at the first failures](history.md#huge-pages-that-stop-at-the-first-failures)).

### Huge files on every worker

`hackage-packages.nix` is 16.6 MB, 42 % of the source nixos-server loads,
and in Rust its parse, compile and IR-cache load run on one thread while
the others wait. iets in Zig spreads all three:

- **The parse.** A set with more than 512 KB of source left is cut at lines
  indented like its first binding, after a line ending in `;`. Idle workers
  parse the chunks as bindings, and the nodes are moved into one tree. Every
  chunk must parse exactly to its end, or nothing is kept and the parse goes
  on sequentially, so the tree and the errors are always the sequential
  ones. `iets parse --chunked` runs it for the parse parity script.
- **The compile.** A plain set of 2048 bindings or more is compiled in
  slices, each with a compiler of its own. A failed slice, or a lint that
  reports, sends the set back to the ordered compile, so warnings come out
  as before.
- **The IR-cache load.** Such a set is stored with a table of where its
  slices start, and several workers read it.

These run as jobs that never park, so the caller spins on the jobs others
run and keeps its worker, whose interner and compile scratch it goes on
using. This step took four workers from 0.432 s to 0.406 s.

### Memory beyond Rust's layout

Peak RSS on nixos-server is 636 MB at one worker against Rust's 726 MB,
and 733 MB at four against 931 MB. Most of the gap comes from small
changes:

- Imported sources are read into the general allocator and freed after
  the compile; nothing the compiler makes points into them.
- A parse tree is reused across files only for sources up to 2 MB.
- `Heap` returns freed blocks of 1 MB or more.
- Past a union's leaf budget, the small leaves after a large first one are
  merged, and the first stays shared.
- The `local` and `constant` IR nodes that recur are shared within a
  thread, which is safe because IR never changes once built.
- There is one empty list and one empty set.

### Fetching on the caller's thread

Rust runs hyper on its own thread and hands frames to the reader through a
bounded queue, because hyper is asynchronous. In Zig the socket is read
through TLS, std's HTTP reader and the decompressors straight into the
spool, on the caller's thread. Each read waits in `poll`, which carries
`stalled-download-timeout` and `connect-timeout`. std's `connect` has no
timeout, so the connect is a nonblocking one in `poll` too.

The decoders are this tree's own where std's measured slower or did less.
bzip2, because std has none. xz, because std's decodes a whole block into
memory and checks no CRC, and a channel tarball is one block of a quarter
gigabyte. zstd, because std's walks the Huffman tree a bit at a time and
copies matches a byte at a time; this one follows libzstd's shape, verifies
the content checksum, decodes a channel tarball in 0.15 s against std's
1.1 s and libzstd's 0.12 s, and keeps runtime safety checks on in every build
mode, because it reads downloaded bytes before the lock's hash can check
them. Gzip is std's.

The input store's spool is mapped once written, where a `pread` per member
had cost 0.35 s of system time on a channel tarball; packing takes the
biggest file first; and the disk starts writing each batch early, so the
final `fsync` waits 10 ms instead of 55 ms. A cold `fetchTree` of
nixos-26.05's `nixexprs.tar.zst` went from 1.68 s to 0.45 s
([A channel tarball, fetched cold](history.md#a-channel-tarball-fetched-cold)).

### Remote builds without an async runtime

Rust's gRPC client is tonic on tokio. Zig's keeps one HTTP/2 connection per
client with a reader thread, and calls block on its condition variable. It
reconnects after a failure or a `GOAWAY`, as tonic's channel does, and waits
for the server's `SETTINGS`, so a refusal after the TLS handshake counts as
a connect error. An `AddMultipleToStore` upload runs on the calling thread,
where Rust needed a producer thread to feed tonic's stream. `FetchNars`
frames are decoded by std's zstd decoder fed one frame at a time: a flushed
frame ends on a block boundary, where the decoder stops for input with its
window intact. The zstd encoder for uploads runs at about 93 % of libzstd
level 1's speed, with a slightly better ratio.

### The derivation lock

A port can carry a design over and still lose its point. `eval-jobs` on a
nixpkgs job set was faster than Rust at one worker and slower past four,
because `derivationStrict` held the derivation table's lock across all its
hashing. Rust's design holds it only for the inputs' part of the modulo
hash and the inserts. With that restored, one process takes 2.81, 0.95 and
0.74 s at 1, 4 and 8 workers against Rust's 3.33, 1.18 and 0.98 s, with the
same 14,560 lines.

## Invisible differences

None of these shows from outside, which is what makes them fine:

- The caches live under `$XDG_CACHE_HOME/iets-zig`. The only text that
  differs from Rust's because of it is the cache path in the help pages,
  which the CLI parity script maps back.
- The memory census differs where the layouts do: the shared empty set and
  list, the flat copy a union gets when iterated, and about 70k more
  closures from applying `zipAttrsWith`'s inner lambda one argument at a
  time.
- The session holds no tree store, eval-jobs walk or library heap; a run
  passes those explicitly. The store directory is process-wide, as in
  Rust, and everything else an evaluation touches is per session or per
  thread, which a test checks by running sessions side by side.
- Provenance takes the derivations' attributes and positions from the
  derivation table instead of collecting them itself.
- `iets diff` and `print-dev-env` keep argument parsers of their own, with
  Rust's errors and suggestions on every flag.
- The layering test's allow-lists are a little wider than Rust's, and
  each extra entry says why.

## Visible differences

These differ from Rust, each checked by running both binaries:

- **Windows.** Rust's Windows code isn't ported; iets in Zig runs on Linux.
- **Where the native stack runs out.** The messages and exit codes of a
  stack overflow are Rust's, but the frames differ in size, so a recursion
  close to the limit (an `==` of lists ten million deep, say) can overflow
  in one binary and finish in the other.
- **A released session.** Rust's library heap turns a released session's
  memory into a tombstone, so a value used after its release faults with
  "a value was used after its session was released". iets in Zig has no
  library heap, and such a use is undefined.
- **TOML errors.** The parser is a port of the `toml` crate's, but it stops
  at the first error instead of recovering, so only the first error shows.
  That is the one both binaries print.

## Lessons from the port

Some of what the port learned applies to any Zig evaluator, and some to any
port:

- **Measure the call, not the code.** Most of the single-thread gain came
  from how results and dispatch compile, not from any algorithm. Look at
  `perf stat` for store-forwarding stalls
  (`ls_bad_status2.stli_other` on Zen 4) before restructuring a hot path.
  perf puts a call's cost on the next instruction, which looks just like a
  stall on the load of its result.
- **Distrust a wall-time difference under 2 %.** Two builds that differ
  only in code nixos-server never runs executed the same 9.986 G
  instructions, 1.9 % apart, because the linker placed the hot code
  differently. Moving the store-directory lookup through the library facade
  once cost 1.5 % at one worker for the same reason. Compare instruction
  counts, and run A and B interleaved, run by run.
- **Port the measured design, then beat it with numbers.** The scheduler,
  the memory layout and the caches came over as Rust had them. Where the
  Zig tree replaced one of Rust's designs (the allocator, the huge-page
  gate, the decoders), a measurement on the same workload came first, and
  the [What was tried and removed](history.md) page keeps the ones that
  lost.
- **Rust habits can be bugs in Zig.** The audit found a ready fiber dropped
  when an append failed (a lost wake-up), a reentrant lock owned by an OS
  thread while fibers migrate, effects dropped on an allocation failure,
  and stdout failures reported as the wrong error. Each was correct under
  Rust's ownership or threading model and wrong under Zig's.
- **Only the claimer may read a thunk's code word.** The publisher
  overwrites it with the value, and an instrumentation that read the word
  of a thunk another fiber held crashed.
- **Count bytes by their known size.** Reading the arena's `used` counter
  before and after an allocation stalled on every thunk, because the
  reload hit the store the allocation had just made.
- **Never hold a lock while forcing.** A force can park, and the fiber can
  resume on another thread. The derivation table uses a recursive lock
  because its loader re-enters it.
- **Write streams as streams.** `std.Io.File.Writer.init` writes at
  positions, so several processes writing to one file overwrite each other;
  stdout and stderr use the streaming writer.
- **Name the build's inputs.** Zig 0.17 caches `build.zig`'s configure
  step, so a value computed there from files goes stale unless each file
  and directory is declared as a dependency.

## Results

On 2026-11-02, the same machine, every run alone (`bench/README.md` has
every tool, version and raw run):

| | Nix 2.34.9 | Rust iets | iets in Zig |
|---|---|---|---|
| nixos-server, 1 worker, cold | 2130 ms · 625 MB | 906 ms · 705 MB | **757 ms · 622 MB** |
| nixos-server, 4 workers, cold | | 489 ms · 907 MB | **372 ms · 729 MB** |
| nixos-server, 8 workers, cold | | 454 ms · 988 MB | **319 ms · 802 MB** |
| nixos-server, 1 worker, warm IR cache | | 773 ms | **675 ms** |
| nixos-server, tracing-cache hit | | 14 ms · 25 MB | **12 ms · 8 MB** |
| whole nixpkgs, 8 workers | 109.4 s (1 thread) | 16.3 s | **9.2 s** |
| cold fetch of a channel `.tar.zst` | | 0.58 s | **0.46 s** |

Every tool gives the same drvPaths, on the NixOS toplevels and on all
82,544 attributes of nixpkgs. The fetch's higher peak RSS (462 MB against
Rust's 311 MB) is the mapped spool, which is page cache rather than iets's
own memory.
