# The transports, measured

How fast does `iets build` ship a closure, and how do you know the bytes
arrive intact? [Builders and the wire](../reference/builders.md) has the
facts about each transport. The numbers here come from one machine and drift
with the nixpkgs pin and the hardware, but the ratios and the op counts hold.
Most of them were measured on Rust iets, which speaks the same protocols with
the same operations, and are labelled so.

## Requests

The worker protocol is serial per connection, and every
`BuildPathsWithResults` starts a new daemon worker. A request per derivation
would leave the daemon idle between derivations, so iets sends one request
for each set that is ready to build.

## Worker protocol timings

Rust iets measured these on the hello closure, with a release build.

"Local daemon" is the system's `nix-daemon`, where the hello closure is
GC-rooted, so a cold run is impossible. "Scratch daemon" is
`nix-daemon --store local?root=DIR` on its own socket: an empty chroot
store, so the cold numbers are real uploads and no build is attempted
(`--no-build`). `ssh-ng://` is the same code over a child's stdio, tested
with an `ssh` shim that runs `nix-daemon --stdio` locally, and against
nixbuild.net ("Against nixbuild.net").

| case | eval | plan | connect | QueryValidPaths | AddMultipleToStore | build (realise) | ops / round trips | bytes sent |
|---|---|---|---|---|---|---|---|---|
| custom drv + 1 source tree, deleted from the store, local daemon, `--fetch-to` | 0.005 s | 0.001 s | 0.077 s | 2 paths, 2 missing, 0.000 s | 2 paths, 2.4 KB, 0.001 s | 0.87 s | 6 / 9 | 2.9 KB |
| hello, local daemon (all valid) | 0.138 s | 0.006 s | 0.074 s | 776 paths, 0 missing, 0.008 s | skipped | 0.001 s | 4 / 7 | 62 KB |
| hello, scratch daemon, cold, `--no-build` | 0.159 s | 0.008 s | 0.020 s | 776 paths, 776 missing, 0.008 s | 776 paths, 2.6 MB, 0.247 s | skipped | 3 / 6 | 2.66 MB |
| hello, scratch daemon, warm, `--no-build` | 0.146 s | 0.007 s | 0.008 s | 776 paths, 0 missing, 0.011 s | skipped | skipped | 2 / 5 | 62 KB |
| nixos-server, scratch daemon, cold, `--no-build` | 1.48 s | 0.094 s | 0.015 s | 4,184 paths, all missing, 0.022 s | 4,184 paths, 40.4 MB, 1.89 s | skipped | 3 / 6 | 40.8 MB |
| nixos-server, scratch daemon, warm, `--no-build` | 1.65 s | 0.112 s | 0.055 s | 4,184 paths, 0 missing, 0.034 s | skipped | skipped | 2 / 5 | 333 KB |
| nixos-server, local daemon, `--no-build` | 1.21 s | 0.121 s | 0.081 s | 4,184 paths, 413 missing, 0.201 s | 413 paths, 23.2 MB, 1.67 s | skipped | 3 / 6 | 23.5 MB |

These rows predate the top-down query. Then the 62 KB of a warm hello run
was the `QueryValidPaths` request: 776 full store paths as padded strings,
and the 776 answers back. With the top-down query, a warm store answers
with the root: the warm hello run against the scratch daemon asks about 1
path and sends 248 bytes, and the hello run against the local daemon asks
about the root and its output, builds nothing, and sends 336 bytes. The
custom drv's 0.87 s "build" is the sandbox build itself. The 413 paths the
local daemon lacked for nixos-server are nixpkgs subtrees that no local
evaluation had copied yet.

The upload is bound by the daemon: 0.3 to 0.5 ms per path for the sequential
`addToStore`. Nothing on the client side changes that
([What was tried and removed](history.md)).

### Against nixbuild.net

Rust iets timed `nix build --store ssh-ng://` (Nix 2.34.8) against
`iets build --builder ssh-ng://` on eu.nixbuild.net. Each derivation is a
few seconds of bash, and a new marker forces a real build.

Two kinds of row bring the output back. "Into the local store" is
`nix copy --from` for Nix and `-o` for iets; both register the path.
"Into a directory" is iets `--fetch-to`, which needs no local store and has
no Nix counterpart.

The figures are provisional: 10 runs on 2026-10-10 from a shared 16-core VM
at load 13 to 21, with a Rust iets that predates the top-down query. `-o` is
not measured yet. Seconds:

| case | Nix mean ± σ | Nix min–max | Rust iets mean ± σ | Rust iets min–max |
|---|---|---|---|---|
| small, new marker | 2.02 ± 0.06 | 1.96–2.12 | 2.04 ± 0.18 | 1.76–2.37 |
| small, new marker, into the local store | 2.39 ± 0.14 | 2.25–2.59 | not measured | |
| small, new marker, into a directory | | | 1.95 ± 0.11 | 1.83–2.19 |
| small, built before (cache hit) | 1.35 ± 0.07 | 1.27–1.44 | 0.97 ± 0.04 | 0.90–1.02 |
| python3 drv closure, 16 MiB output | 2.60 ± 0.05 | 2.49–2.66 | 2.29 ± 0.07 | 2.19–2.37 |
| the same, into the local store | 3.21 ± 0.10 | 3.12–3.40 | not measured | |
| the same, into a directory | | | 2.56 ± 0.26 | 2.36–3.22 |

A [nix-wire](https://github.com/numtide/nix-wire) recording of that run
shows the same session for both clients: `QueryValidPaths` on 818 paths,
one `AddMultipleToStore`, one `BuildPathsWithResults` of 1.1 s, and no
`SetOptions`. Nix adds `QueryMissing` and `QueryPathInfo`; iets adds
`QueryDerivationOutputMap`. With the top-down query, an iets cache hit
sends two one-path queries: 232 bytes instead of 66 KB.

The difference is evaluation. At load 2, Rust iets evaluated the file in
0.115 s and Nix in 0.51 s.

iets needs no local store here: with no `nix` on `PATH` and no daemon
socket, it runs only `ssh` and writes the output to `--fetch-to`.

### Upload integrity

Rust iets's `tests/e2e_daemon.rs` runs against this binary
(`scripts/rust-tests.sh BIN e2e_daemon`, each test on a private
nix-daemon). After an upload it checks that:

- the `.drv` file in the store is `cmp`-identical to the one
  `nix-instantiate` wrote before it was deleted;
- `nix-store -q --hash`, `nix derivation show` and `nix path-info --json`
  (`ca`, `narHash`, `narSize`, `references`) match for the derivation and
  for the source;
- in the scratch store, the derivation has the same hash as in the local
  store, and every input source has the same `ca`.

`src/remote/worker/daemon_tests.zig` drives the protocol without the
command line against the machine's daemon: the handshake, path infos,
`NarFromPath` hashed against its path info, a small path through
`AddMultipleToStore`, `QueryMissing`, and the same protocol through an
`ssh` shim.

## The `grpc://` transport

Rust iets measured these on the hello closure, with a release build.

`nix-grpc-daemon` runs in plaintext standalone mode, scheduling onto itself,
in front of a scratch chroot store. These are the transport's own figures,
not a farm's.

| case | connect | QueryValidPaths | AddMultipleToStore | build | RPCs |
|---|---|---|---|---|---|
| custom drv + 1 source tree, `--fetch-to` | 0.009 s | 2 paths, 2 missing, 0.020 s | 2 paths, 721 B, 0.009 s | 0.63 s | 6 |
| hello cold, `--no-build` | 0.000 s | 776 paths, 776 missing, 0.006 s | 776 paths, 490 KB, 0.26 s | skipped | 3 |
| hello warm, `--no-build` | 0.000 s | 776 paths, 0 missing, 0.006 s | skipped | skipped | 2 |

The cold hello upload is 490 KB on the wire, against 2.66 MB over the
worker protocol. The bytes are the same; `grpc://` sends them as one zstd
stream across all 776 paths. This binary's zstd encoder is its own: it
follows libzstd's level 1 and runs at about 93 % of its speed, with a
slightly better ratio.

The client is one HTTP/2 connection per endpoint with a reader thread; a
call blocks on that connection until its answer arrives, so there is no
asynchronous runtime. It reconnects after a failure or a `GOAWAY`, and an
`AddMultipleToStore` upload runs on the calling thread.

Rust iets's `tests/e2e_grpc.rs` runs against this binary with a real
`nix-grpc-daemon` (`IETS_TEST_NIX_GRPC_DAEMON=… scripts/rust-tests.sh BIN
e2e_grpc`). It checks that:

- classic `nix build --store grpc://…?insecure=1 --eval-store auto` prints
  the same stdout as the real nix with its nix-grpc-store plugin;
- an out-link whose output no local substituter has is fetched back with
  `FetchNars` and handed to the local daemon;
- `iets build --builder grpc://… --json` gives the same outcome per
  attribute as the worker protocol on the same store;
- a multi-root `iets build` over `grpc://` names every attribute on
  stderr.

`src/remote/grpc/server_tests.zig` covers the client without a daemon, with
a stand-in server: the retry on `UNAVAILABLE`, many concurrent calls on one
connection, `FetchNars`, the upload stream byte for byte, the `Schedule`
stream, and TLS with client certificates.

Against `farm.numtide.com` with a Keycloak `write` token (measured on Rust
iets, 2026-09-20), a `runCommand` with 572 cached inputs went `Want`,
`Assigned`, `BuildDerivation` on a farm worker in 2.6 s and 5 RPCs. A
classic `nix-build` out-link came from cache.numtide.com through the local
daemon.

On 2026-10-11, a one-line derivation on nixpkgs bash, 10 runs
after one warm-up, with the output already in the farm's cache:

| client | mean ± σ |
|---|---|
| Nix 2.36 with its nix-grpc-store plugin | 14.5 ± 6.7 s |
| Rust iets, every path asked in one call | 34.6 ± 21.7 s |
| Rust iets, asked top-down | 0.246 ± 0.018 s |

On this farm a large `QueryValidPaths` is slow: the node publishes each
path it holds to niks3 before it replies. iets asked about the 818 planned
paths and then about 700 output paths. Top-down, a cache hit is two
calls about one path each.

With a new marker, Nix took 46 s to 296 s and Rust iets 20 s to 304 s, and
the farm's own work was most of it. Uploading the one new `.drv` (533 bytes)
took 6 s to 37 s, because the node fetches the `.drv` closure from the cache
before it imports. A `.drv` with no references uploaded in 2 s to 3 s.
Sending the closure in the stream was slower, and so was uploading only
after a worker answered `NOT_FOUND`.

### Bounced addresses

A worker that crashed stays placeable until the scheduler notices. On
farm.numtide.com that took 42 s (measured on 2026-09-22), and every bounce
off the dead worker was instant, so a client that only retried would burn
its retries in a second. All builds of one run therefore share what they
learn about an address ("Retries" in
[Builders and the wire](../reference/builders.md)).

## NAR parity

`src/store/nar_parity.zig` checks that the NAR iets writes is byte-identical
to `nix-store --dump` on a tree of awkward names, empty files and
directories, symlinks, executables, odd alignment, deep nesting and a large
file. It also checks that a restored dump dumps back to the same bytes, and
that the reader rejects a truncated archive, a misspelled keyword and
non-zero padding. Each test skips itself when `nix-store` is absent.

Rust iets measured its NAR code on an AMD EPYC Genoa with a warm page cache,
on the pinned nixpkgs tree (40k entries, 212 MB of NAR) and one 500 MB file:

| case | Rust iets | Nix |
|---|---|---|
| NAR hash of the tree | 665-672 ms | `nix hash path` 1665 ms |
| dump of the tree, no hash | 545-567 ms | `nix-store --dump \| sha256sum` 2034 ms |
| NAR hash of a 500 MB file | 353-359 ms | `nix hash path` 386 ms |
| restore of the tree from a pipe | 1744-1804 ms | `nix-store --restore` 2019 ms |
