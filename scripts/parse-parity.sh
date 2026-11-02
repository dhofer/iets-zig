#!/usr/bin/env bash
# `iets parse` output, text and --json, sequential and chunked, against
# Rust on every .nix file of
# nixpkgs and ../iets/tests, in batches; errors (stderr) are compared too.
# usage: scripts/parse-parity.sh [ZIG_BIN] [RUST_BIN]
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
zig=${1:-$here/zig-out-rel/bin/iets}
rust=${2:-$here/../iets/target/release/iets}
np=${NIXPKGS:-/nix/store/6nwzgfvznah5rg192x0hnl5ykchdgi59-source}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
find "$np" "$here/../iets/tests" -name '*.nix' -type f | sort > "$tmp/files"
split -l 500 "$tmp/files" "$tmp/batch."
bad=0
for b in "$tmp"/batch.*; do
  # --chunked: huge sets parsed in chunks on threads, as with workers
  for mode in "" "--json" "--chunked" "--chunked --json"; do
    "$zig" parse $mode $(cat "$b") > "$tmp/z.out" 2> "$tmp/z.err"
    "$rust" parse ${mode#--chunked} $(cat "$b") > "$tmp/r.out" 2> "$tmp/r.err"
    # Rust's summary line carries its timing
    grep -v '^[0-9]* files, ' "$tmp/r.err" > "$tmp/r.err2"
    grep -v '^[0-9]* files, ' "$tmp/z.err" > "$tmp/z.err2"
    if ! cmp -s "$tmp/z.out" "$tmp/r.out" || ! cmp -s "$tmp/z.err2" "$tmp/r.err2"; then
      echo "DIFF in $b ${mode:-text}"; bad=1
      diff <(head -c 2000000 "$tmp/z.out") <(head -c 2000000 "$tmp/r.out") | head -5
      diff "$tmp/z.err2" "$tmp/r.err2" | head -5
    fi
  done
done
echo "$(wc -l < "$tmp/files") files"
[ $bad = 0 ] && echo PARSE PARITY
exit $bad
