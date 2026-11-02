# iets in Zig

A Zig 0.17 implementation of [iets](https://github.com/numtide/iets), the
fast Nix evaluator and client. It began as a port of the Rust tree and
aims for the same behaviour, byte for byte; see
[numtide/iets](https://github.com/numtide/iets) for what iets is and how to
use it.

```sh
zig build -Doptimize=ReleaseFast   # zig-out/bin/iets
zig build test
```

The parity scripts in `scripts/` compare against Rust iets checked out as
`../iets`. Contributor notes are in `AGENTS.md` and `docs/explanation/`.

LGPL-2.1, as iets; see `COPYING`.
