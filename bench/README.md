# Benchmarks against the other evaluators

You changed iets-zig and want to know where it stands against Nix,
Determinate Nix, Rust iets and fix, without timing all of them again.
`bench/run.sh` reruns iets-zig alone and prints each row beside the saved
numbers of the others:

```sh
zig build -Doptimize=ReleaseFast --prefix zig-out-rel
bench/run.sh nixos          # NixOS drvPaths, cold, warm, a tracing-cache hit (a minute or two)
bench/run.sh full           # the whole-nixpkgs universe at 4 and 8 workers (about a minute, 24 GB)
FETCH_DIR=… bench/run.sh fetch   # a cold fetch of the channel tarball
```

`nixos` refuses to time a binary whose drvPath differs from Nix's, and
`full` prints how many of the 82,544 attributes differ from the saved Nix
output (`results/2026-11-02/full/nix.json.zst`). Compare only on the
machine in [`env.txt`](results/2026-11-02/env.txt): a saved number is a
number of that machine on that day. The same Rust iets binary took 1086 ms
on nixos-server at one worker on 2026-10-31 and 906 ms on 2026-11-02, and
a run that fills most of memory (the whole nixpkgs universe) depends on how
fragmented free memory is, so time a fresh Rust iets beside iets-zig before
you trust a gap of a few percent (`scripts/bench.sh
../iets/target/release/iets` takes a minute).

## The numbers, 2026-11-02

Ryzen 9 7950X, 62 GB, nixpkgs 26.11pre; every tool and version is in
[`env.txt`](results/2026-11-02/env.txt). Every run is alone on the machine.
iets-zig is commit `abf9557`; it and Rust iets were timed in one session,
the other tools earlier the same day.

**NixOS toplevel drvPath**, median of 5 runs after one warmup, wall time and
peak RSS. Cold: every cache off. Warm: iets's IR cache (its tracing cache
off) and fix's compile cache. Nix and Determinate Nix have no cache for
this.

| tool | minimal | server | plasma |
|---|---|---|---|
| Nix 2.34.9 | 1722 ms · 599 MB | 2130 · 625 | 3203 · 841 |
| Determinate Nix 3.24.1, 1 core | 1777 · 721 | 2234 · 870 | 3268 · 1189 |
| Determinate Nix, 4 cores | 1507 · 781 | 1885 · 955 | 2408 · 1269 |
| Determinate Nix, 8 cores | 1474 · 840 | 1846 · 1020 | 2259 · 1345 |
| Determinate Nix, all cores | 1522 · 1038 | 1907 · 1243 | 2309 · 1680 |
| iets, 1 worker, cold | 717 · 600 | 906 · 705 | 1296 · 848 |
| iets, 4 workers, cold | 399 · 783 | 489 · 907 | 628 · 1092 |
| iets, 8 workers, cold | 367 · 926 | 454 · 988 | 548 · 1238 |
| **iets-zig, 1 worker, cold** | **589 · 508** | **757 · 622** | **1104 · 830** |
| **iets-zig, 4 workers, cold** | **289 · 616** | **372 · 729** | **485 · 923** |
| **iets-zig, 8 workers, cold** | **252 · 690** | **319 · 802** | **391 · 1016** |
| fix, 1 worker, cold ¹ | 2031 · 1285 | 2582 · 1817 | 3663 · 2614 |
| fix, 4 workers, cold ¹ | 904 · 1405 | 1189 · 1997 | 1620 · 2596 |
| fix, 8 workers, cold ¹ | 648 · 1388 | 940 · 1994 | 1279 · 2717 |
| fix, 12 workers (its default), cold ¹ | 691 · 1533 | 955 · 1971 | 1340 · 2793 |
| iets, 1 worker, warm | 587 · 548 | 773 · 653 | 1154 · 837 |
| iets, 4 workers, warm | 315 · 693 | 404 · 838 | 533 · 1023 |
| iets, 8 workers, warm | 291 · 843 | 362 · 958 | 460 · 1177 |
| **iets-zig, 1 worker, warm** | **510 · 484** | **675 · 599** | **1016 · 808** |
| **iets-zig, 4 workers, warm** | **253 · 538** | **334 · 655** | **446 · 859** |
| **iets-zig, 8 workers, warm** | **227 · 579** | **297 · 691** | **358 · 908** |
| fix, 1 worker, warm ¹ | 1592 · 1270 | 2109 · 1802 | 3136 · 2618 |
| fix, 4 workers, warm ¹ | 760 · 1341 | 1048 · 2003 | 1441 · 2600 |
| fix, 8 workers, warm ¹ | 583 · 1336 | 863 · 1967 | 1142 · 2614 |
| fix, 12 workers, warm ¹ | 609 · 1347 | 862 · 1927 | 1215 · 2651 |
| iets, tracing-cache hit | 7 · 21 | 14 · 25 | 15 · 26 |
| iets-zig, tracing-cache hit | 5 · 7 | 12 · 8 | 12 · 8 |

**The whole nixpkgs universe**: nixpkgs' CI job set, 82,544 attributes, 243
of them errors that every tool catches. One run each, every cache off.

| tool | wall | user | sys | peak RSS | drvPaths unlike Nix's |
|---|---|---|---|---|---|
| Nix 2.34.9 | 109.4 s | 156.6 s | 7.7 s | 18.1 GB | — |
| Determinate Nix, 1 core | 108.1 s | 133.1 s | 7.6 s | 17.8 GB | 0 |
| Determinate Nix, 8 cores | 80.5 s | 157.7 s | 19.7 s | 18.3 GB | 0 |
| Determinate Nix, all cores | 82.3 s | 192.3 s | 40.7 s | 18.7 GB | 0 |
| iets, 4 workers | 20.0 s | 48.2 s | 14.3 s | 21.5 GB | 0 |
| iets, 8 workers | 16.3 s | 54.7 s | 17.3 s | 21.9 GB | 0 |
| **iets-zig, 4 workers** | **13.2 s** | 41.1 s | 6.3 s | 22.6 GB | **0** |
| **iets-zig, 8 workers** | **9.2 s** | 47.8 s | 9.8 s | 22.8 GB | **0** |
| fix, 4 workers ¹ | 66.4 s | 195.4 s | 55.2 s | 42.4 GB | 16 |
| fix, 12 workers ¹ | 52.9 s | 385.2 s | 138.9 s | 42.5 GB | 16 |

**A cold fetch** of nixos-26.05's `nixexprs.tar.zst` (40 MB, 269 MB of tar,
90k members) into an empty input store, from a local file, no daemon;
median of 7. Nix and fix were not timed.

| archive | iets | iets-zig |
|---|---|---|
| `.tar.zst` | 0.58 s · 311 MB | **0.46 s** · 462 MB |
| `.tar.gz` | 0.80 s · 317 MB | **0.68 s** · 476 MB |

¹ fix's drvPaths are wrong: in a derivation with `__structuredAttrs`, it
writes a control character such as ESC unescaped into `__json`, where Nix
writes `\u001b`. NixOS's `/etc/issue` holds ESC, so every NixOS toplevel
differs, and so do 16 nixpkgs attributes (`results/…/full/fix-differs.jsonl`).
Its plain `builtins.toJSON` escapes correctly. The smallest case:
`(derivation { name = "x"; system = "x86_64-linux"; builder = "/bin/sh";
__structuredAttrs = true; t = builtins.fromJSON "\"\\u001b\""; }).drvPath`
is `w160ibxr…-x.drv` in Nix and iets, `8y0i8zdx…-x.drv` in fix. The timings
are kept: it does the same work, to a wrong hash.

## What the files hold

`results/2026-11-02/`:

- `env.txt`: the machine, every binary with its commit or store path and how
  it was built, and the expected drvPaths and output hash.
- `nixos/WORKLOAD.SET.json`: hyperfine's raw JSON, every run with wall,
  user, sys and peak RSS, one file per set: `main` (Nix and fix), `detsys`,
  `iets`, `iets-zig`. hyperfine 2.0 does not export the `-n` names;
  `SET.names.txt` gives them in the order of `results[]`. `.log` is
  hyperfine's terminal output.
- `nixos/summary.tsv`: the median, min, max and peak RSS of every row; what
  `run.sh` reads.
- `nixos/drvpaths.txt`: each tool's output on each workload.
- `full/times.tsv`: GNU time of each run and how many attributes differ from
  Nix. `full/nix.json.zst`: Nix's whole output (`{ attr = drvPath | null; }`).
  `full/sorted-sha256.txt`: the sha256 of each output normalized with
  `jq -S -c 'to_entries[]' | sort`; Nix, Determinate Nix, iets and iets-zig
  share one. The other outputs are 9.2 MB each and not kept.
- `fetch.tsv`: the fetch medians. Per-run lines were not kept.

## Measuring all of it again

`bench/reproduce/` holds the scripts that made these numbers. They take the
binaries from the environment:

```sh
FIX=… DETSYS=… OUT=… bench/reproduce/nixos.sh     # some 8 minutes
FIX=… DETSYS=… OUT=… bench/reproduce/full.sh      # some 12 minutes, up to 45 GB a run
bench/reproduce/fetch.sh prep DIR && FETCH_DIR=DIR bench/reproduce/fetch.sh run
```

Getting the other tools without touching the installed Nix:

- Determinate Nix: `nix build --no-link --print-out-paths
  github:DeterminateSystems/nix-src/v3.24.1#nix-cli` builds it from source
  (some 10 minutes); `DETSYS` is that store path.
- fix: in a checkout at the commit in `env.txt`, with the Zig 0.16 that
  `env.txt` names: `zig build --release=fast --prefix DIR --cache-dir DIR2`;
  `FIX` is `DIR/bin/fix`.
- hyperfine: `nix build nixpkgs#hyperfine`; set `HYPERFINE` if it is not on
  `PATH`.

## What to watch for

- **Same output first.** Check every tool's drvPaths against Nix before
  timing it; that is how fix's escaping bug showed. Nix's `--eval` writes the
  `.drv` files of a drvPath it computes; `--readonly-mode` stops that, so it
  does the same work as the others.
- **Caches out of the way.** Every run gets `XDG_CACHE_HOME` of its own:
  Rust iets keeps its caches in `~/.cache/iets`, iets-zig in
  `~/.cache/iets-zig`, fix in `~/.cache/fix` (`--compile-cache-dir`
  moves it). Cold rows turn every cache off (`--no-cache`,
  `--no-compile-cache`); warm rows keep the tracing cache off
  (`--no-tracing-cache`), since a hit skips the evaluation.
- **Workers.** iets and iets-zig default to the cores, at most 4; fix to
  `min(12, cores)`, through `--workers`, which its `--help` hides;
  Determinate Nix to one core, `--eval-cores 0` is all of them. Nix has
  one thread.
- **The full universe runs alone.** fix peaks at 45 GB, the others at 18 to
  24 GB, on a 62 GB machine.
- **A fetch is not measured over the network or through a daemon.** curl
  takes 2.2 to 3 s for the 40 MB from releases.nixos.org here, which drowns
  the difference; a run reads the archive from `file://`. A daemon would
  substitute the channel tarball's tree from cache.nixos.org (13 s, writing
  `/nix/store`), so the run points the store at nothing
  (`NIX_CONFIG="store = unix:///nonexistent"`) and `prep` repacks the
  archive with one file more, so no store holds its tree. To fetch over the
  network after all, `NIX_STORE_DIR=/tmp/nonexistent-store` names the tree
  in another store directory.
- **Profiles miss kernel time.** `perf record` here can only sample user
  space (`perf_event_paranoid=2`): a per-member `pread` showed up as a slow
  SHA-256. `getrusage(RUSAGE_THREAD)` or GNU time's sys column shows it,
  and `/proc/vmstat` read before and after a run says what the kernel did
  (`compact_stall`, `thp_fault_alloc`, `thp_fault_fallback`, `pgfault`).
