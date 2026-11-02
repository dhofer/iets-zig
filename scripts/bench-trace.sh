#!/usr/bin/env bash
# The tracing cache on nixos-server: median wall time of RUNS runs of each
# mode at each worker count. Modes: `cold` (--no-cache), `notrace` (a warm IR
# cache, --no-tracing-cache), `miss` (a warm IR cache, the tracing cache on,
# its entry removed before each run: the cost of recording), `hit`.
# usage: scripts/bench-trace.sh [BIN] [WORKERS...]   (default zig-out-rel/bin/iets, 1 4)
#        BIN=../iets/target/release/iets for Rust
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
bin=${1:-$here/zig-out-rel/bin/iets}
shift || true
np=${NIXPKGS:-/nix/store/6nwzgfvznah5rg192x0hnl5ykchdgi59-source}
runs=${RUNS:-9}
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
export IETS_CACHE_DIR=$dir
wl=$here/../iets/bench/workloads/nixos-server.nix
ev() { "$bin" eval "$@" --impure --strict -I nixpkgs="$np" "$wl" >/dev/null 2>&1; }
ev --no-tracing-cache
for w in "${@:-1 4}"; do
  for w1 in $w; do
    for mode in cold notrace miss hit; do
      [ "$mode" = hit ] && ev --workers "$w1"
      for _ in $(seq "$runs"); do
        case $mode in
          cold) flags=(--no-cache) ;;
          notrace) flags=(--no-tracing-cache) ;;
          miss) rm -rf "$dir/trace"; flags=() ;;
          hit) flags=() ;;
        esac
        s=$(date +%s%N)
        ev "${flags[@]}" --workers "$w1"
        echo $(( ($(date +%s%N) - s) / 1000000 ))
      done | sort -n | awk -v w="$w1" -v m="$mode" '{a[NR]=$1} END{printf "workers %s %-8s median %5s ms (min %s, max %s)\n", w, m, a[int((NR+1)/2)], a[1], a[NR]}'
    done
  done
done
