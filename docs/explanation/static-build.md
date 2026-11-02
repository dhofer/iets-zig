# The build and its allocator

`zig build -Doptimize=ReleaseFast` gives you one `iets` binary for Linux.
Every build is Linux only: the evaluator uses futexes, `/proc/self` and
Linux `madvise` flags. The binary links glibc. It needs no daemon and no
`/nix/store` to evaluate, and it carries what a fetch needs to trust a
server.

It runs `git` for a project that is a git checkout, and `nix` for a locked
`git` or `hg` input. If the machine has no CA bundle, the binary trusts the
Mozilla roots built into it, and `NIX_SSL_CERT_FILE` overrides them
([Settings](../reference/settings.md)).

## The allocator

The evaluator keeps its values in its own arena, one per worker, and
everything else comes from the general allocator. In a release build that is
`Heap` (`src/Heap.zig`), not glibc's malloc. A debug build keeps
`DebugAllocator` for its leak checks.

The reason is page faults. A worker thread's glibc heap starts as fresh
4 KB pages, and on nixos-server those cost 30k page faults and 50 ms at one
worker, most of a worker's system time. `Heap` has the small path of
`std.heap.SmpAllocator` (power-of-two size classes, a free list per class
per thread slot, slabs of one class), but every byte comes from 64 MB
segments advised to be huge pages. A freed block waits on its class's list
for the next request, and only a block of 1 MB or more gives its pages back
to the kernel.
An evaluation's peak is its working set, so keeping memory costs nothing a
run would get back.

Rust iets links mimalloc for the same job. `Heap` is a Zig allocator in its
place, chosen over linking mimalloc's C source.

## Rust iets's allocator measurements

Rust iets has a static musl build, and measured every allocator on both
libcs before choosing mimalloc. The table is Rust iets's, timed with
hyperfine (1 warmup, 5 runs, median) on an idle Ryzen 9 7950X3D pinned to
cores 0–7. The baseline is glibc's malloc.

| variant | server w1 | server w4 | minimal w1 | outpaths 0/8 w1 | outpaths 0/8 w4 |
|---|---:|---:|---:|---:|---:|
| glibc, system | 0.97 s | 0.47 s | 0.74 s | 24.4 s | 9.05 s |
| glibc, mimalloc | −7% | −7% | −8% | −8% | −7% |
| glibc, jemalloc | −4% | −4% | −5% | −7% | −7% |
| glibc, tcmalloc | −3% | −4% | −4% | −4% | −5% |
| glibc, rpmalloc | −3% | −2% | −3% | −6% | −7% |
| glibc, snmalloc | −2% | −1% | −2% | −2% | −6% |
| glibc, scudo | +5% | +3% | +4% | +4% | −1% |
| glibc, dlmalloc | +3% | +83% | +3% | +2% | +1% |
| glibc, rlsf | +4% | +93% | +4% | +3% | +1% |
| musl, mimalloc | +3% | +5% | 0% | +3% | +3% |
| musl, jemalloc | +7% | +10% | +5% | +4% | +4% |
| musl, dlmalloc | +12% | +70% | +10% | +12% | +12% |
| musl, rlsf | +12% | +78% | +10% | +11% | +10% |
| musl, system | +26% | +79% | +24% | +30% | +29% |

`server w4` is the nixos-server workload at four workers; `w1` is one
worker. Two results carry over to any static build of this tree. musl's own
malloc is 24–30 % slower, and 79 % at four workers, so a static build needs
`Heap` or another allocator of its own. And even with mimalloc the Rust
static build stayed 9–13 % slower than its glibc build, mostly in musl's
`memcpy`, `memmove`, `memcmp` and `memset`, which took 13.8 % of the cycles
on server w1 where glibc's took 2.9 %.
