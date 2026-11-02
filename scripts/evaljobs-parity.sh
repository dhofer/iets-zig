#!/usr/bin/env bash
# `iets eval-jobs` against the Rust oracle on the jobsets of
# ../iets/tests/evaljobs: the flag combinations of tests/e2e_evaljobs.rs
# that need no flakes, each in the default worker-process mode and in one
# process (`--max-memory-size 0`). stdout is compared line by line, sorted
# (worker processes finish in any order) and without `stats`; stderr
# sorted and without the summary lines that carry timings; the exit code
# and the `--gc-roots-dir` entries exactly. The `.drv`s go to the local
# daemon: every job is a tiny derivation.
# usage: scripts/evaljobs-parity.sh [BIN]   (default zig-out/bin/iets)
#   NIXPKGS=/nix/store/...-source adds the cases that import nixpkgs.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
bin=$(realpath "${1:-$here/zig-out/bin/iets}")
oracle=${ORACLE:-$here/../iets/target/release/iets}
fixtures=$(cd "$here/../iets/tests/evaljobs" && pwd)
nixpkgs=${NIXPKGS:-}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0

# The JSON lines without `stats`, keys sorted, lines sorted.
norm_out() {
  python3 -I -c '
import json, sys
out = []
for l in open(sys.argv[1], encoding="utf-8", errors="surrogateescape"):
    l = l.rstrip("\n")
    try:
        v = json.loads(l)
    except ValueError:
        out.append("not json: " + l)
        continue
    if isinstance(v, dict):
        v.pop("stats", None)
    out.append(json.dumps(v, sort_keys=True))
out.sort()
print("\n".join(out))
' "$1"
}

# stderr without the timing lines of the summary and the session id,
# sorted.
norm_err() {
  grep -v -e '^eval-jobs: [0-9]* jobs' -e '^instantiate: [0-9]* batches' -e '"msg":"eval-jobs: [0-9]* jobs' "$1" |
    sed -e 's/"sid":"[^"]*"/"sid":""/' | sort
}

run() { # tool, dir, stdin, args...
  local tool=$1 dir=$2 stdin=$3
  shift 3
  (cd "$fixtures" && "$tool" eval-jobs "$@" <"$stdin" >"$dir.out" 2>"$dir.err"; echo "rc=$?" >"$dir.rc")
}

check() { # name, stdin ('' for none), args...
  local name=$1 stdin=${2:-/dev/null}
  shift 2
  [ "$stdin" = /dev/null ] || stdin=$fixtures/$stdin
  local a=()
  # iets evaluates a file purely and nix-eval-jobs follows nix.conf, so a
  # file case gets `--impure`, as e2e_evaljobs.rs does
  case " $* " in *" --impure "*) ;; *) a+=(--impure) ;; esac
  for mode in workers single; do
    local m=()
    [ $mode = single ] && m=(--max-memory-size 0)
    local ok=1
    for side in o z; do
      local tool=$oracle
      [ $side = z ] && tool=$bin
      rm -rf "$tmp/$side.gc" && mkdir -p "$tmp/$side.gc"
      local args=()
      for x in "$@"; do args+=("${x//GCROOTS/$tmp/$side.gc}"); done
      run "$tool" "$tmp/$side" "$stdin" "${a[@]}" "${m[@]}" "${args[@]}"
      norm_out "$tmp/$side.out" >"$tmp/$side.nout"
      norm_err "$tmp/$side.err" >"$tmp/$side.nerr"
      ls "$tmp/$side.gc" >"$tmp/$side.ls"
    done
    for f in rc nout nerr ls; do
      if ! cmp -s "$tmp/o.$f" "$tmp/z.$f"; then
        ok=0
        echo "FAIL $name ($mode): $f differs"
        diff "$tmp/o.$f" "$tmp/z.$f" | head -20
      fi
    done
    if [ $ok = 1 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi
  done
}

apply='drv: { the-name = drv.name; version = drv.version or null; outs = drv.outputs or [ "out" ]; }'
impure='{ x = derivation { name = "x-${builtins.currentSystem}"; system = builtins.currentSystem; builder = ":"; }; }'

check basic '' ci.nix
check meta '' --meta ci.nix
check force-recurse '' --meta --force-recurse ci.nix
check no-instantiate '' --meta --no-instantiate --gc-roots-dir GCROOTS ci.nix
check input-drvs '' --show-input-drvs ci.nix
check gc-roots '' --gc-roots-dir GCROOTS --meta ci.nix
check apply '' --apply "$apply" ci.nix
check apply-error '' --apply 'drv: drv.name' ci.nix
check select '' --select 'jobs: { inherit (jobs) builtJob recurse; }' --meta ci.nix
check expr '' --expr 'import ./ci.nix { system = "aarch64-linux"; }' --meta
check expr-E '' -E '(import ./ci.nix { }).recurse' --meta
check argstr '' --argstr system aarch64-linux ci.nix
check arg '' --arg system '"i686-linux"' ci.nix
check arg-from-file '' --arg-from-file system system.txt ci.nix
check arg-from-stdin system.txt --arg-from-stdin system ci.nix
check option '' --option allow-import-from-derivation false --show-trace --quiet --max-jobs 1 --log-format raw ci.nix
check verbose '' --verbose --debug ci.nix
check log-format-json '' --log-format internal-json --show-trace ci.nix
check impure '' --impure --expr "$impure"
check constituents '' --constituents --gc-roots-dir GCROOTS --meta aggregates.nix
check constituents-select '' --constituents --select 'j: { inherit (j) success; }' aggregates.nix
check ca '' --extra-experimental-features ca-derivations --no-instantiate --meta ca.nix
check ca-workers '' --extra-experimental-features ca-derivations --no-instantiate --workers 3 ca.nix
check cache-status-constituents '' --check-cache-status --constituents --gc-roots-dir GCROOTS aggregates.nix
check chunk0 '' --chunks 2 --chunk 0 --meta ci.nix
check chunk1 '' --chunks 2 --chunk 1 --meta ci.nix
check chunk-depth '' --chunks 3 --chunk 1 --chunk-depth 1 --force-recurse ci.nix
check provenance '' --provenance --no-instantiate ci.nix
check restart '' --max-memory-size 1 --meta ci.nix
check root-throws '' --expr 'throw "boom"'
check root-function '' --expr '{ x ? 1 }: { a = derivation { name = "a${toString x}"; system = "x"; builder = ":"; }; }' --arg x 2 --no-instantiate
check numeric-names '' --no-instantiate --expr '{ "9" = derivation { name = "nine"; system = "x"; builder = ":"; }; }'
check empty-root '' --no-instantiate --expr '{ }'
check empty-root-forced '' --no-instantiate --force-recurse --expr '{ a = { }; }'
# usage errors and the flags iets refuses
check no-instantiate-constituents '' --no-instantiate --constituents aggregates.nix
check no-instantiate-cache '' --no-instantiate --check-cache-status ci.nix
check no-instantiate-input-drvs '' --no-instantiate --show-input-drvs ci.nix
check select-not-attrs '' --select 'x: "str"' ci.nix
check no-expr ''
check bad-chunk '' --chunks 2 --chunk 2 ci.nix
check bad-number '' --chunks two ci.nix
check bad-store '' --eval-store 'https://example.invalid' ci.nix
check override '' --override-input a b ci.nix
check repair '' --repair ci.nix
check unknown-flag '' --chunk-dept 1 ci.nix
check missing-file '' --arg-from-file system nonexistent.txt ci.nix
if [ -n "$nixpkgs" ]; then
  check include '' --include "nixpkgs=$nixpkgs" --expr '{ inherit (import <nixpkgs> { }) hello; }' --no-instantiate
  check cache-status '' --check-cache-status --meta -I "nixpkgs=$nixpkgs" cache.nix
fi

# tests/e2e_evaljobs.rs's own checks of iets alone.
expect() { # name, then a command that must succeed
  local name=$1
  shift
  if "$@"; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    echo "FAIL $name"
  fi
}
two='{ a = builtins.trace "a" (derivation { name = "a"; system = "x"; builder = ":"; }); b = builtins.trace "b" (derivation { name = "b"; system = "x"; builder = ":"; }); }'
sids() { # IETS_SESSION_ID or '': the distinct sids of one run's records
  env ${1:+IETS_SESSION_ID=$1} "$bin" eval-jobs --workers 2 --no-instantiate --log-format internal-json --expr "$two" 2>&1 >/dev/null |
    sed -n 's/^@nix .*"sid":"\([^"]*\)".*/\1/p' | sort | uniq -c | awk '{print $1, $2}'
}
one_sid() {
  local s
  s=$(sids '')
  [ "$(echo "$s" | wc -l)" = 1 ] && [ "${s%% *}" = 3 ] && [ "$(echo "$s" | cut -c17)" = 7 ] &&
    [ "$(sids run-42)" = "3 run-42" ]
}
expect one-session-id-per-run one_sid
every_line_has_stats() {
  (cd "$fixtures" && "$bin" eval-jobs --workers 2 --no-instantiate ci.nix 2>/dev/null) | python3 -I -c '
import json, sys
ls = [json.loads(l) for l in sys.stdin]
assert ls and all(isinstance(l["stats"]["wallMs"], int) and isinstance(l["stats"]["allocBytes"], int) for l in ls)
assert any(l["stats"]["allocBytes"] > 0 for l in ls)
'
}
expect every-line-has-stats every_line_has_stats
warn_once() {
  local got
  got=$(cd "$fixtures" && "$bin" eval-jobs --workers 2 --no-instantiate --verbose --debug --verbose --max-jobs 1 --quiet ci.nix 2>&1 >/dev/null | grep '^warning: ')
  [ "$got" = "warning: '--verbose' is ignored: iets has one log level, the one Nix starts at
warning: '--debug' is ignored: iets has one log level, the one Nix starts at" ]
}
expect ignored-flags-warn-once warn_once
options_reach_workers() {
  (cd "$fixtures" && "$bin" eval-jobs --iets-option cache-dir "$tmp/opt-cache" --workers 2 --no-instantiate ci.nix >/dev/null 2>&1) &&
    [ -e "$tmp/opt-cache" ]
}
expect iets-options-reach-the-workers options_reach_workers

echo "evaljobs-parity: $pass passed, $fail failed"
[ $fail = 0 ]
