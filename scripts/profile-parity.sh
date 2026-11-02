#!/usr/bin/env bash
# IETS_PROFILE stacks against the Rust oracle on programs with curried,
# over-applied and functor calls and primop applications. Samples are timed,
# so the counts differ run to run: this compares the set of stacks, the union
# over RUNS runs of each binary; a stack counts as missing only when the
# other binary shows it in at least half its runs.
#
# usage: [RUNS=3] [HZ=5000] scripts/profile-parity.sh [BIN]
set -u
here=$(cd "$(dirname "$0")" && pwd)
R=$here/../../iets/target/release/iets
Z=${1:-$here/../zig-out-rel/bin/iets}
RUNS=${RUNS:-3}
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
G="builtins.genList (x: x) 200000"
progs=(
  "let f = a: b: c: a + b + c; in builtins.foldl' (acc: x: acc + f x x x) 0 ($G)"
  "let id = x: x; g = a: b: a + b; in builtins.foldl' (acc: x: acc + id g x x) 0 ($G)"
  "let add = builtins.add; inc = builtins.add 1; in builtins.foldl' (acc: x: inc (add acc x)) 0 ($G)"
  "let f = {a, b}: x: a + b + x; mk = n: {a = n; b = n;}; in builtins.foldl' (acc: x: acc + f (mk x) x) 0 ($G)"
  "let s = { __functor = self: x: x + 1; }; in builtins.foldl' (acc: x: acc + s x) 0 ($G)"
  "let f = a: let g = b: c: a + b + c; in g; in builtins.foldl' (acc: x: acc + f x x x) 0 ($G)"
  "let m = builtins.map; in builtins.length (builtins.concatLists (m (x: m (y: y + x) [1 2 3]) ($G)))"
)
bad=0 i=0
for p in "${progs[@]}"; do
  i=$((i + 1))
  for b in R Z; do
    : > "$D/$b.all"
    for _ in $(seq "$RUNS"); do
      # a run that writes no profile must not leave the last program's
      rm -f "$D/$b.out"
      IETS_PROFILE=eval IETS_PROFILE_TO="$D/$b.out" IETS_PROFILE_HZ=${HZ:-5000} "${!b}" eval --no-cache --workers 1 --expr "$p" >/dev/null 2>&1
      [ -f "$D/$b.out" ] && sed 's/ [0-9]*$//' "$D/$b.out" | sort -u >> "$D/$b.all"
    done
    # each stack with the number of runs it showed up in
    sort "$D/$b.all" | uniq -c | awk '{n=$1; $1=""; print substr($0,2) "\t" n}' | sort > "$D/$b.cnt"
  done
  # A stack a short-lived call makes may miss every sample of a run, so a
  # difference is a stack one binary shows in half its runs or more and the
  # other never shows.
  missing=$(join -t $'\t' -v1 "$D/R.cnt" "$D/Z.cnt" | awk -F'\t' -v h=$((RUNS / 2)) '$2 >= h {print "< " $1}'
    join -t $'\t' -v1 "$D/Z.cnt" "$D/R.cnt" | awk -F'\t' -v h=$((RUNS / 2)) '$2 >= h {print "> " $1}')
  if [ -n "$missing" ]; then
    bad=$((bad + 1))
    echo "=== $p"
    echo "$missing"
  fi
done
echo "profile parity: $i programs, $bad differ"
[ "$bad" = 0 ]
