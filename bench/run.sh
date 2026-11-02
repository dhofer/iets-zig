#!/usr/bin/env bash
# Reruns only iets-zig and prints each row beside the saved baselines of the
# other tools (bench/results/$BASE), so an iets-zig change is measured
# without timing Nix, Determinate Nix, Rust iets and fix again.
#
#   bench/run.sh nixos [BIN]        # the NixOS drvPath rows, cold, warm, hit
#   bench/run.sh full  [BIN]        # the whole-nixpkgs universe, once per worker count
#   bench/run.sh fetch [BIN]        # a cold fetch of the channel tarball (needs FETCH_DIR)
#
# Environment: BIN (default zig-out-rel/bin/iets), NIXPKGS, WORKLOADS,
# WORKERS (default "1 4 8"; full: "4 8"), RUNS (default 5), BASE (default
# 2026-11-02), OUT (default a new temporary directory). See bench/README.md.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
mode=${1:?usage: bench/run.sh nixos|full|fetch [BIN]}
bin=$(realpath "${2:-${BIN:-$here/../zig-out-rel/bin/iets}}")
np=${NIXPKGS:-/nix/store/6nwzgfvznah5rg192x0hnl5ykchdgi59-source}
base=$here/results/${BASE:-2026-11-02}
out=${OUT:-$(mktemp -d -t iets-bench-XXXXXX)}
hf=${HYPERFINE:-$(command -v hyperfine || echo /nix/store/li3z6xnjj65z8hfdlcx3lb48vaphl51w-hyperfine-2.0.0/bin/hyperfine)}
gnu_time=${TIME_BIN:-/run/current-system/sw/bin/time}
workloads=${IETS_WORKLOADS:-$here/../../iets/bench/workloads}
mkdir -p "$out"
# every cache in a directory of its own, never ~/.cache/iets-zig
export XDG_CACHE_HOME=$out/cache

baseline() { # workload row -> "wall_ms rss_mb", or "-"
  awk -F'\t' -v w="$1" -v r="$2" '$1 == w && $2 == r { print $3 " ms " $6 " MB"; f = 1 } END { if (!f) print "-" }' "$base/nixos/summary.tsv"
}

case $mode in
nixos)
  for w in ${WORKLOADS:-nixos-minimal nixos-server nixos-plasma}; do
    f=$workloads/$w.nix
    want=$(awk -v w="$w" '$1 == w && $2 == "nix" { print $3 }' "$base/nixos/drvpaths.txt")
    got=$("$bin" eval --impure --strict --no-cache -I nixpkgs="$np" "$f")
    [ "$got" = "$want" ] || { echo "$w: drvPath $got, Nix gives $want" >&2; exit 1; }
    rm -rf "$XDG_CACHE_HOME"
    rows=() args=()
    for n in ${WORKERS:-1 4 8}; do
      rows+=("iets-zig w$n cold")
      args+=(-n "w$n cold" "$bin eval --impure --strict --no-cache --workers $n -I nixpkgs=$np $f")
    done
    for n in ${WORKERS:-1 4 8}; do
      rows+=("iets-zig w$n warm")
      args+=(-n "w$n warm" "$bin eval --impure --strict --no-tracing-cache --workers $n -I nixpkgs=$np $f")
    done
    rows+=("iets-zig hit")
    args+=(-n "hit" "$bin eval --impure --strict -I nixpkgs=$np $f")
    "$hf" --shell=none --warmup 1 --runs "${RUNS:-5}" --export-json "$out/$w.json" "${args[@]}" > "$out/$w.log" 2>&1
    echo "== $w (drvPath matches Nix)"
    printf '%-20s %-18s %-18s %-18s %-18s %s\n' row now saved "iets (Rust)" "Nix" "Determinate, 8 cores"
    i=0
    while read -r ms mb; do
      r=${rows[$i]}
      printf '%-20s %-18s %-18s %-18s %-18s %s\n' "$r" "$ms ms $mb MB" "$(baseline "$w" "$r")" \
        "$(baseline "$w" "${r/iets-zig/iets}")" "$(baseline "$w" nix)" "$(baseline "$w" 'detsys c8')"
      i=$((i + 1))
    done < <(jq -r '.results[] | "\(.summary.time_wall_clock.median * 1000 | round) \(.summary.memory_peak_resident.median / 1048576 | round)"' "$out/$w.json")
  done
  ;;
full)
  ref=$out/nix.sorted
  zstd -dc "$base/full/nix.json.zst" | jq -S -c 'to_entries[]' | sort > "$ref"
  printf '%-10s %-10s %-10s %-10s %-12s %s\n' run wall user sys "peak RSS" "differ from Nix"
  for n in ${WORKERS:-4 8}; do
    rm -rf "$XDG_CACHE_HOME"
    "$gnu_time" -f "%e %U %S %M" -o "$out/w$n.time" "$bin" eval --impure --strict --json --no-cache --workers "$n" \
      "$here/outpaths.nix" --arg nixpkgs "$np" > "$out/w$n.json" 2> "$out/w$n.err"
    jq -S -c 'to_entries[]' "$out/w$n.json" | sort > "$out/w$n.sorted"
    read -r wl us sy kb < "$out/w$n.time"
    printf '%-10s %-10s %-10s %-10s %-12s %s\n' "w$n" "$wl s" "$us s" "$sy s" "$((kb / 1048576)) GB" "$(( $(comm -3 "$ref" "$out/w$n.sorted" | wc -l) / 2 ))"
    awk -F'\t' -v r="zig-w$n" '$1 == r { printf "%-10s %-10s %-10s %-10s %-12s %s\n", "  saved", $2 " s", $3 " s", $4 " s", int($5 / 1048576) " GB", $7 }' "$base/full/times.tsv"
  done
  echo "saved, other tools:"
  awk -F'\t' 'NR > 1 && $1 !~ /^zig-/ { printf "  %-10s %-10s peak RSS %d GB, %s differ\n", $1, $2 " s", $5 / 1048576, $7 }' "$base/full/times.tsv"
  ;;
fetch)
  dir=${FETCH_DIR:?set FETCH_DIR to the directory bench/reproduce/fetch.sh prep made}
  hash=$(cat "$dir/narhash")
  for a in zst gz; do
    for _ in $(seq "${RUNS:-7}"); do
      rm -rf "$XDG_CACHE_HOME"; mkdir -p "$XDG_CACHE_HOME"
      expr="(builtins.fetchTree { type = \"tarball\"; url = \"file://$dir/bench.tar.$a\"; narHash = \"$hash\"; }).outPath"
      NIX_CONFIG="store = unix:///nonexistent" "$gnu_time" -f "%e %U %S %M" "$bin" eval --raw --no-cache --expr "$expr" 2>&1 >/dev/null | tail -1
    done | sort -n | awk -v a="tar.$a" '{ w[NR] = $1; u[NR] = $2; s[NR] = $3; m[NR] = $4 } END { i = int((NR + 1) / 2); printf "%-8s now %s s, user %s s, sys %s s, %d MB\n", a, w[i], u[i], s[i], m[i] / 1024 }'
  done
  echo "saved:"; column -t "$base/fetch.tsv"
  ;;
*) echo "usage: bench/run.sh nixos|full|fetch [BIN]" >&2; exit 2 ;;
esac
echo "raw output: $out"
