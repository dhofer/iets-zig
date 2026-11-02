#!/usr/bin/env bash
# Deep recursion against the Rust oracle: max-call-depth, the force path's
# stack check, the parser, and the guard page of a fiber stack (`--workers
# 4`, the fault handler's message) and of the evaluator thread (`--workers
# 1`, the runtime's abort). Output and exit code must match; thread ids are
# masked.
#
# usage: scripts/deep-parity.sh [BIN]
set -u
here=$(cd "$(dirname "$0")" && pwd)
R=$here/../../iets/target/release/iets
Z=$(realpath "${1:-$here/../zig-out-rel/bin/iets}")
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
python3 - "$D" <<'PY'
import sys
d = sys.argv[1]
open(d + '/parens.nix', 'w').write('(' * 100000 + '1' + ')' * 100000)
open(d + '/parens5k.nix', 'w').write('(' * 5000 + '1' + ')' * 5000)
open(d + '/list.json', 'w').write('[' * 100000 + ']' * 100000)
open(d + '/lets.nix', 'w').write('let a0 = 0; ' + ' '.join('a%d = a%d + 1;' % (i + 1, i) for i in range(200000)) + ' in a200000')
open(d + '/neg.nix', 'w').write('-' * 200000 + '1')
open(d + '/sel.nix', 'w').write('{}' + '.a' * 20000 + ' or 1')
open(d + '/attrs.nix', 'w').write('{a=' * 50000 + '1' + ';}' * 50000)
open(d + '/lists.nix', 'w').write('[' * 100000 + ']' * 100000)
open(d + '/str.nix', 'w').write('"' + '${"' * 20000 + 'x' + '"}' * 20000 + '"')
PY
F='let f = n: if n == 0 then [] else [(f (n - 1))]; in'
G='let f = n: if n == 0 then {} else {a = f (n - 1);}; in'
H='let f = n: acc: if n == 0 then acc else f (n - 1) [acc]; in'
L="builtins.foldl' (a: x: [a]) [] (builtins.genList (x: x)"
cases=(
  "--strict --expr|$F f 100000"
  "--expr|$F builtins.toJSON (f 100000)"
  "--expr|$F builtins.deepSeq (f 100000) 1"
  "--expr|$F f 100000 == f 100000"
  "--expr|$F toString (f 100000)"
  "--strict --expr|$G f 100000"
  "--expr|$G builtins.toJSON (f 100000)"
  "--expr|$G builtins.toXML (f 100000)"
  "--expr|$H builtins.deepSeq (f 1000000 []) 1"
  "--expr|$H builtins.toJSON (f 1000000 [])"
  "--strict --expr|$H f 1000000 []"
  "--expr|$H (f 1000000 []) == (f 1000000 [])"
  "--expr|$H builtins.toXML (f 1000000 [])"
  "--expr|$H builtins.toString (f 1000000 [])"
  "--expr|let g = n: if n == 0 then 0 else 1 + g (n - 1); in g 1000000"
  "--expr|builtins.fromJSON (builtins.readFile $D/list.json)"
  "--expr|builtins.length (builtins.fromJSON (builtins.readFile $D/list.json))"
  "|$D/parens.nix"
  "|$D/parens5k.nix"
  "|$D/lets.nix"
  "|$D/neg.nix"
  "|$D/sel.nix"
  "--strict|$D/attrs.nix"
  "--strict|$D/lists.nix"
  "|$D/str.nix"
  "--expr|$L 1000000)"
  "--strict --expr|$L 1000000)"
  "--json --expr|$L 1000000)"
  "--expr|builtins.deepSeq ($L 1000000)) 1"
  "--expr|builtins.toJSON (builtins.foldl' (a: x: {a = a;}) {} (builtins.genList (x: x) 1000000))"
  "--expr|let l = $L 1000000); in l == l"
  "--expr|let l = $L 1000000); m = $L 1000000); in l == m"
  "--expr|builtins.toXML ($L 1000000))"
  "--expr|toString ($L 1000000))"
  "--expr|builtins.seq (builtins.foldl' (a: x: a + x) 0 (builtins.genList (x: x) 1000000)) 1"
  "--expr|let s = builtins.genList (i: if i == 0 then 0 else builtins.elemAt s (i - 1) + 1) 1000000; in builtins.elemAt s 999999"
  "--expr|let l = $L 30000000); m = $L 30000000); in l == m"
)
run() {
  (cd /tmp && timeout 120 "$@" 2>&1; echo "rc=$?") | sed -e 's/^\(thread .<unknown>. \)([0-9]*)/\1(TID)/' -e "s|$D|<D>|g"
}
bad=0 n=0
for w in 1 4; do
  for c in "${cases[@]}"; do
    n=$((n + 1))
    flags=${c%%|*} arg=${c#*|}
    # shellcheck disable=SC2086
    r=$(run "$R" eval --no-cache --workers $w $flags "$arg")
    # shellcheck disable=SC2086
    z=$(run "$Z" eval --no-cache --workers $w $flags "$arg")
    if [ "$r" != "$z" ]; then
      bad=$((bad + 1))
      echo "=== workers $w: $flags ${arg:0:100}"
      diff <(echo "$r") <(echo "$z") | head -8
    fi
  done
done
echo "deep parity: $n cases, $bad differ"
[ "$bad" = 0 ]
