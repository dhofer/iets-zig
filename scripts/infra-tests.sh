#!/usr/bin/env bash
# The Rust integration tests of the infrastructure, against BIN (default the
# debug build): tests/events.rs, tests/profile.rs, tests/progress.rs and the
# evaluation half of tests/e2e_provenance.rs. Each case runs in the
# hermetic environment of tests/hermetic (an empty environment, a home of
# its own, no nix.conf, progress off). Run it on ../iets/target/release/iets
# too: both must pass. usage: scripts/infra-tests.sh [BIN]
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
bin=${1:-$here/zig-out/bin/iets}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home"
# a project root, so a pure evaluation reads below it (src/project.zig)
touch "$work/iets.toml"
cd "$work" || exit 1
fails=0

# tests/hermetic: only PATH and TMPDIR come through.
iets() {
  env -i PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" HOME="$work/home" XDG_CACHE_HOME="$work/home/.cache" \
    XDG_CONFIG_DIRS=/nonexistent NIX_CONF_DIR=/nonexistent NIX_STORE_DIR=/nix/store \
    IETS_COMPLETE_MS=0 IETS_PROGRESS=false "$@"
}

check() { # NAME CONDITION-RESULT TEXT
  if [ "$2" = 0 ]; then echo "ok   $1"; else echo "FAIL $1"; printf '%s\n' "$3" | sed 's/^/     /' | head -20; fails=$((fails + 1)); fi
}
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# events.rs ------------------------------------------------------------------
to_file='"${builtins.toFile "t" "hi"}"'
err=$(iets env IETS_EVENTS=store "$bin" eval --no-cache --raw -E "$to_file" 2>&1 >/dev/null); rc=$?
line=$(printf '%s\n' "$err" | head -1)
has "$line" '"event":"store-add"' && has "$line" '"kind":"text"' && has "$line" '"size":2' &&
  has "$line" '"from":"text"' && has "$line" '-t"' && has "$line" '"at":"«string»:1:4"' && [ $rc = 0 ]
check "events: a text add names its size and its position" $? "$err"

echo hello > "$work/src.txt"
err=$(iets env IETS_EVENTS=store "$bin" eval --no-cache --raw -E "\"\${/. + \"$work/src.txt\"}\"" 2>&1 >/dev/null)
real=$(realpath "$work/src.txt")
has "$err" '"kind":"tree"' && has "$err" "\"from\":\"$real\""
check "events: a tree add names the local path it copied" $? "$err"

ok=0
for g in all store,fetch; do
  err=$(iets env IETS_EVENTS=$g "$bin" eval --no-cache --raw -E "$to_file" 2>&1 >/dev/null)
  has "$err" store-add || ok=1
done
check "events: all takes the cold groups" $ok "$err"

ok=0
for g in - fetch ""; do
  if [ "$g" = - ]; then err=$(iets "$bin" eval --no-cache --raw -E "$to_file" 2>&1 >/dev/null)
  else err=$(iets env IETS_EVENTS="$g" "$bin" eval --no-cache --raw -E "$to_file" 2>&1 >/dev/null); fi
  [ -z "$err" ] || ok=1
done
check "events: a group nobody named says nothing" $ok "$err"

err=$(iets env IETS_EVENTS=store,stor "$bin" eval --no-cache --raw -E "$to_file" 2>&1 >/dev/null); rc=$?
has "$err" "IETS_EVENTS: 'stor' is not an event group" && has "$err" "all, syntax" && [ $rc != 0 ]
check "events: a group that does not exist is a settings error" $? "$err"

err=$(iets env IETS_EVENTS=store IETS_EVENTS_TO="$work/e.jsonl" "$bin" eval --no-cache --raw -E "$to_file" 2>&1 >/dev/null); rc=$?
[ $rc = 0 ] && [ -z "$err" ] && has "$(cat "$work/e.jsonl" 2>/dev/null)" '"event":"store-add"'
check "events: the sink is its own knob" $? "$err"

# profile.rs -----------------------------------------------------------------
prof() { iets env "$@" "$bin" eval --no-cache --workers 1 -E "$expr"; }
expr=1; err=$(prof IETS_PROFILE=cpu 2>&1 >/dev/null); rc=$?
has "$err" "IETS_PROFILE: 'cpu' is not 'eval'" && [ $rc != 0 ]
check "profile: a profile that is not eval is a settings error" $? "$err"

err=$(prof 2>&1 >/dev/null)
! has "$err" profile
check "profile: an unprofiled run says nothing about a profile" $? "$err"

expr='1 + 1'; err=$(prof IETS_PROFILE=eval 2>&1 >/dev/null); rc=$?
has "$err" "profile: no samples" && [ $rc = 0 ]
check "profile: a run shorter than a tick says it sampled nothing" $? "$err"

expr="let f = n: if n == 0 then 0 else g (n - 1); g = n: f n; in builtins.foldl' (a: _: a + f 400) 0 (builtins.genList (x: x) 4000)"
prof IETS_PROFILE=eval IETS_PROFILE_TO="$work/p.folded" IETS_PROFILE_HZ=1000 >/dev/null 2>&1
deepest=$(awk '{n=split($1,a,";"); for(i=1;i<=n;i++) if(a[i]=="") bad=1; if ($2 !~ /^[0-9]+$/) bad=1; if(n>d) d=n} END{print bad ? -1 : d+0}' "$work/p.folded" 2>/dev/null)
[ "${deepest:-0}" -gt 2 ]
check "profile: a folded line is a stack and a count" $? "deepest $deepest"

expr="builtins.length (builtins.foldl' (a: _: a ++ builtins.genList (x: x) 50) [] (builtins.genList (x: x) 2000))"
prof IETS_PROFILE=eval IETS_PROFILE_TO="$work/b.folded" IETS_PROFILE_HZ=1000 >/dev/null 2>&1
grep -q ':«' "$work/b.folded" 2>/dev/null
check "profile: a builtin names itself in a frame" $? "$(head -3 "$work/b.folded" 2>/dev/null)"

expr="builtins.length (builtins.foldl' (a: _: a ++ builtins.genList toString 200) [] (builtins.genList (x: x) 2000))"
prof IETS_PROFILE=alloc IETS_PROFILE_TO="$work/a.folded" IETS_PROFILE_HZ=1000 >/dev/null 2>&1
weighed=$(awk '{s+=$NF} END{print s+0}' "$work/a.folded" 2>/dev/null)
[ "${weighed:-0}" -gt $((1 << 20)) ]
check "profile: an allocation profile weighs arena bytes" $? "weighed $weighed"

err=$(iets env IETS_PROFILE=eval "$bin" eval --no-cache --workers 4 -E 1 2>&1 >/dev/null); rc=$?
has "$err" "--workers must be 1, not 4" && [ $rc != 0 ]
r1=$?
err2=$(iets env IETS_PROFILE=eval IETS_WORKERS=4 "$bin" eval --no-cache -E 1 2>&1 >/dev/null); rc=$?
has "$err2" "workers must be 1, not 4" && [ $rc != 0 ] && [ $r1 = 0 ]
check "profile: a profile refuses more than one worker" $? "$err
$err2"

# progress.rs ----------------------------------------------------------------
# Rust's test holds a download open; with no fetcher here a computation of
# more than five seconds stands in for it.
slow="builtins.foldl' (a: b: a + b) 0 (builtins.genList (x: builtins.foldl' (a: b: a + b) 0 (builtins.genList (y: y) 3000)) ${SLOW_N:-150000})"
err=$(iets env IETS_PROGRESS=true IETS_CACHE=0 "$bin" eval --strict --workers 1 -E "$slow" 2>&1 >/dev/null)
tick=$(printf '%s\n' "$err" | grep -m1 '^⏵ ')
has "$tick" "evaluating the expression"
check "progress: a pipe hears of a run that takes five seconds" $? "$err"

# e2e_provenance.rs, the evaluation half ------------------------------------
mkdir -p "$work/case/src"
echo 'throw "boom from the tree"' > "$work/case/src/bad.nix"
err=$(iets "$bin" eval --no-cache -E "import \"\${$work/case/src}/bad.nix\"" 2>&1 >/dev/null)
has "$err" "$work/case/src/bad.nix:1:1" && ! has "$err" "/nix/store/"
check "provenance: an error in a copied tree names the local file" $? "$err"

err=$(iets env IETS_PROVENANCE=0 "$bin" eval --no-cache -E "import \"\${$work/case/src}/bad.nix\"" 2>&1 >/dev/null)
has "$err" "/nix/store/" && ! has "$err" "$work/case/src/bad.nix"
check "provenance: IETS_PROVENANCE=0 keeps the store path" $? "$err"

echo
[ $fails = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
