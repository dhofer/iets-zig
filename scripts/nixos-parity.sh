#!/usr/bin/env bash
# drvPath parity on ../iets/bench/workloads/nixos-server.nix: the Zig port
# (ReleaseFast) against the Rust iets. NIXPKGS picks the nixpkgs tree.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
iets=$here/../iets
np=${NIXPKGS:-/nix/store/6nwzgfvznah5rg192x0hnl5ykchdgi59-source}
out=${OUT:-$here/zig-out-rel}
(cd "$here" && zig build -Doptimize=ReleaseFast --prefix "$out")
w=$iets/bench/workloads/nixos-server.nix
want=$("$iets/target/release/iets" eval --impure --strict --no-tracing-cache --workers 1 -I nixpkgs="$np" "$w")
got=$(/usr/bin/env time -f "zig: %es %MKB" "$out/bin/iets" eval --impure --strict -I nixpkgs="$np" "$w") || true
echo "rust: $want"
echo "zig:  $got"
[ "$want" = "$got" ] && echo PARITY || { echo MISMATCH; exit 1; }
