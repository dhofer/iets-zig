#!/usr/bin/env bash
# The whole-nixpkgs universe (bench/outpaths.nix over nixpkgs' own
# ci/eval/outpaths.nix: 82,544 attributes, 243 caught errors), once per tool
# and worker count, one after another: two runs at once would share 62 GB.
# Peak RSS is 18-45 GB a run. Nix takes some two minutes, the whole set
# some twelve. Then each output is normalized (`jq -S -c 'to_entries[]' |
# sort`) and compared with Nix's.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
np=${NIXPKGS:-/nix/store/6nwzgfvznah5rg192x0hnl5ykchdgi59-source}
NIX=${NIX:-nix-instantiate}
RUST=${RUST:-$here/../../iets/target/release/iets}
ZIG=${ZIG:-$here/../zig-out-rel/bin/iets}
FIX=${FIX:-}
DETSYS=${DETSYS:-}
T=${TIME_BIN:-/run/current-system/sw/bin/time}
x=$here/outpaths.nix
out=${OUT:-$(mktemp -d -t iets-full-XXXXXX)}
mkdir -p "$out"
cd "$out" || exit 1
export XDG_CACHE_HOME=$out/cache
run() { # label command...
  local l=$1; shift
  rm -rf "$XDG_CACHE_HOME"; mkdir -p "$XDG_CACHE_HOME"
  "$T" -f "%e %U %S %M" -o "$l.time" "$@" > "$l.json" 2> "$l.err"
  echo "$l exit $? $(cat "$l.time")"
}
for job in ${JOBS:-nix rust-w4 rust-w8 zig-w4 zig-w8 fix-w4 fix-w12 detsys-c1 detsys-c8 detsys-c0}; do
  case $job in
    nix) run nix "$NIX" --eval --strict --json --readonly-mode "$x" --arg nixpkgs "$np" ;;
    rust-w*) run "$job" "$RUST" eval --impure --strict --json --no-cache --workers "${job#rust-w}" "$x" --arg nixpkgs "$np" ;;
    zig-w*) run "$job" "$ZIG" eval --impure --strict --json --no-cache --workers "${job#zig-w}" "$x" --arg nixpkgs "$np" ;;
    fix-w*) [ -n "$FIX" ] && run "$job" "$FIX" eval --strict --json --no-progress --no-compile-cache --workers "${job#fix-w}" --option pure-eval false "$x" --arg nixpkgs "$np" ;;
    detsys-c*) [ -n "$DETSYS" ] && run "$job" "$DETSYS/bin/nix-instantiate" --eval --strict --json --readonly-mode --eval-cores "${job#detsys-c}" "$x" --arg nixpkgs "$np" ;;
  esac
done
for f in *.json; do jq -S -c 'to_entries[]' "$f" | sort > "${f%.json}.sorted"; done
if [ -f nix.sorted ]; then
  for f in *.sorted; do echo "${f%.sorted}: $(( $(comm -3 nix.sorted "$f" | wc -l) / 2 )) attributes differ from nix"; done
fi
echo "raw output: $out"
