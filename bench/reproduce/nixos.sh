#!/usr/bin/env bash
# The NixOS drvPath matrix of every tool, as measured on 2026-11-02: hyperfine,
# one warmup, RUNS measured runs, raw JSON per workload into OUT. Takes some
# 8 minutes. Rows per workload:
#   nix; iets and iets-zig at 1, 4, 8 workers cold, warm and on a tracing-cache
#   hit; fix at 1, 4, 8, 12 workers cold and warm; Determinate Nix at 1, 4, 8
#   and 0 (all) eval cores.
# Set NIX, RUST, ZIG, FIX, DETSYS to the binaries (see bench/README.md for
# how each was built). The names of the rows are in the order of the JSON
# results: hyperfine 2.0 does not export `-n` names.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
hf=${HYPERFINE:-hyperfine}
np=${NIXPKGS:-/nix/store/6nwzgfvznah5rg192x0hnl5ykchdgi59-source}
W=${IETS_WORKLOADS:-$here/../../iets/bench/workloads}
NIX=${NIX:-nix-instantiate}
RUST=${RUST:-$here/../../iets/target/release/iets}
ZIG=${ZIG:-$here/../zig-out-rel/bin/iets}
FIX=${FIX:?set FIX to a ReleaseFast fix binary}
DETSYS=${DETSYS:?set DETSYS to Determinate Nix nix-cli store path}
out=${OUT:-$(mktemp -d -t iets-matrix-XXXXXX)}
C=$out/cache
mkdir -p "$out"
for w in ${WORKLOADS:-nixos-minimal nixos-server nixos-plasma}; do
  f=$W/$w.nix
  rm -rf "$C"; mkdir -p "$C"
  e="env XDG_CACHE_HOME=$C"
  # Nix writes .drv files when it evaluates a drvPath; --readonly-mode stops
  # that, so it does what the others do
  a=(-n "nix" "$NIX --eval --strict --readonly-mode --option pure-eval false -I nixpkgs=$np $f")
  for n in 1 4 8; do
    a+=(-n "iets w$n cold" "$e $RUST eval --impure --strict --no-cache --workers $n -I nixpkgs=$np $f")
    a+=(-n "iets-zig w$n cold" "$e $ZIG eval --impure --strict --no-cache --workers $n -I nixpkgs=$np $f")
  done
  for n in 1 4 8 12; do
    a+=(-n "fix w$n cold" "$e $FIX eval --strict --no-progress --no-compile-cache --workers $n --option pure-eval false -I nixpkgs=$np $f")
  done
  for n in 1 4 8; do
    a+=(-n "iets w$n warm" "$e $RUST eval --impure --strict --no-tracing-cache --workers $n -I nixpkgs=$np $f")
    a+=(-n "iets-zig w$n warm" "$e $ZIG eval --impure --strict --no-tracing-cache --workers $n -I nixpkgs=$np $f")
  done
  for n in 1 4 8 12; do
    a+=(-n "fix w$n warm" "$e $FIX eval --strict --no-progress --compile-cache-dir $C/fix --workers $n --option pure-eval false -I nixpkgs=$np $f")
  done
  a+=(-n "iets hit" "$e $RUST eval --impure --strict -I nixpkgs=$np $f")
  a+=(-n "iets-zig hit" "$e $ZIG eval --impure --strict -I nixpkgs=$np $f")
  "$hf" --shell=none --warmup 1 --runs "${RUNS:-5}" --export-json "$out/$w.main.json" "${a[@]}" > "$out/$w.main.log" 2>&1
  d=()
  for c in 1 4 8 0; do
    d+=(-n "detsys c$c" "$DETSYS/bin/nix-instantiate --eval --strict --readonly-mode --eval-cores $c --option pure-eval false -I nixpkgs=$np $f")
  done
  "$hf" --shell=none --warmup 1 --runs "${RUNS:-5}" --export-json "$out/$w.detsys.json" "${d[@]}" > "$out/$w.detsys.log" 2>&1
  echo "done $w"
done
echo "raw output: $out"
