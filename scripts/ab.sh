#!/usr/bin/env bash
# Two binaries on nixos-server, interleaved run by run (A, B, A, B, ...):
# the median wall time and user-space instructions of each, cold (no
# caches). Back-to-back medians drift by 20 ms on a busy machine, so a
# change is judged on interleaved runs only.
# usage: [RUNS=9] scripts/ab.sh A_BIN B_BIN [WORKERS...]   (default 1 4)
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
a=$1 b=$2
shift 2
np=${NIXPKGS:-/nix/store/6nwzgfvznah5rg192x0hnl5ykchdgi59-source}
runs=${RUNS:-9}
wl=$here/../iets/bench/workloads/nixos-server.nix
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

one() { # BIN WORKERS: "ms instructions"
  local s e
  s=$(date +%s%N)
  perf stat -x, -e instructions:u -o "$tmp/stat" -- "$1" eval --no-cache --workers "$2" \
    --impure --strict -I nixpkgs="$np" "$wl" >"$tmp/out" 2>/dev/null
  e=$(date +%s%N)
  echo "$(((e - s) / 1000000)) $(grep instructions "$tmp/stat" | cut -d, -f1)"
}

median() { sort -n | awk '{v[NR]=$1} END{print v[int((NR+1)/2)]}'; }

for w in "${@:-1 4}"; do
  : >"$tmp/a" && : >"$tmp/b"
  for _ in $(seq "$runs"); do
    one "$a" "$w" >>"$tmp/a"
    cp "$tmp/out" "$tmp/a.out"
    one "$b" "$w" >>"$tmp/b"
    cmp -s "$tmp/out" "$tmp/a.out" || { echo "workers $w: the outputs differ" >&2; exit 1; }
  done
  am=$(cut -d' ' -f1 "$tmp/a" | median) bm=$(cut -d' ' -f1 "$tmp/b" | median)
  ai=$(cut -d' ' -f2 "$tmp/a" | median) bi=$(cut -d' ' -f2 "$tmp/b" | median)
  awk -v w="$w" -v am="$am" -v bm="$bm" -v ai="$ai" -v bi="$bi" 'BEGIN{
    printf "workers %s: A %d ms, B %d ms (%+.1f %%); A %.3f G, B %.3f G instructions (%+.2f %%)\n",
      w, am, bm, (bm - am) * 100 / am, ai / 1e9, bi / 1e9, (bi - ai) * 100 / ai }'
done
