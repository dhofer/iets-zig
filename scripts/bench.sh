#!/usr/bin/env bash
# Wall time on nixos-server: the median of RUNS runs at each worker count.
# usage: [CACHE=1] scripts/bench.sh [BIN] [WORKERS...]   (default zig-out-rel/bin/iets, 1 4)
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
bin=${1:-$here/zig-out-rel/bin/iets}
shift || true
np=${NIXPKGS:-/nix/store/6nwzgfvznah5rg192x0hnl5ykchdgi59-source}
runs=${RUNS:-9}
# Cold by default: no IR cache. CACHE=1 measures a warm IR cache instead
# (the tracing cache, which would skip the evaluation, stays off).
if [ -n "${CACHE:-}" ]; then
  extra=(--no-tracing-cache)
  "$bin" eval "${extra[@]}" --impure --strict -I nixpkgs="$np" "$here/../iets/bench/workloads/nixos-server.nix" >/dev/null 2>&1
else
  extra=(--no-cache)
fi
for w in "${@:-1 4}"; do
  for w1 in $w; do
    for _ in $(seq "$runs"); do
      s=$(date +%s%N)
      "$bin" eval "${extra[@]}" --workers "$w1" --impure --strict \
        -I nixpkgs="$np" "$here/../iets/bench/workloads/nixos-server.nix" >/dev/null 2>&1
      echo $(( ($(date +%s%N) - s) / 1000000 ))
    done | sort -n | awk -v w="$w1" '{a[NR]=$1} END{printf "workers %s: median %s ms (min %s, max %s)\n", w, a[int((NR+1)/2)], a[1], a[NR]}'
  done
done
