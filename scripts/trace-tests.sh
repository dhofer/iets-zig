#!/usr/bin/env bash
# The tracing cache's integration tests against BIN (default the debug build):
# Rust's tests/cache_semantics.rs and the command-line half of
# tests/cache_hygiene.rs, then a parity pass that runs the same steps on BIN
# and on the oracle (../iets/target/release/iets) and compares stdout, the
# `cache:` and `re-evaluating:` lines, the exit code and `iets cache dump`
# byte for byte, each binary in a cache directory of its own: the formats
# are each binary's own, and the two must never share a store.
#
# Not here, for want of what they test: the flake cases (flake/ is not
# ported: a_flake_keeps_one_entry, a_pure_run_never_reads_an_impure_entry),
# `iets nix eval` (classic mode, in uncacheable_runs_write_nothing) and
# `iets search` (search_uses_the_cache); tests/classic_cache.rs is all
# classic commands.
# usage: scripts/trace-tests.sh [BIN]
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
bin=$(realpath "${1:-$here/zig-out/bin/iets}")
oracle=$(realpath "${ORACLE:-$here/../iets/target/release/iets}")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home"
cd "$here/../iets" || exit 1
fails=0
clock=1000000000

check() { # NAME CONDITION-RESULT TEXT
  if [ "$2" = 0 ]; then echo "ok   $1"; else echo "FAIL $1"; printf '%s\n' "$3" | sed 's/^/     /' | head -20; fails=$((fails + 1)); fi
}
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# tests/hermetic, and the environment of cache_semantics.rs's `Work::iets`
iets() {
  env -i PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" HOME="$work/home" XDG_CONFIG_DIRS=/nonexistent \
    NIX_CONF_DIR=/nonexistent NIX_STORE_DIR=/nix/store IETS_PROGRESS=false \
    IETS_CACHE_DIR="${cache:-$work/cache}" CACHETEST_VAR="${CACHETEST_VAR:-one}" ${EXTRA_ENV:-} "$@"
}

# write REL TEXT: each write gets an mtime of its own, long past, so the cache
# trusts the stat of every file and counts only the rehashes a test causes
write() {
  mkdir -p "$(dirname "$work/$1")"
  printf '%s' "$2" > "$work/$1"
  clock=$((clock + 1))
  touch -d "@$clock" "$work/$1"
}

# ev BIN ARGS: `iets eval --impure --strict --timings ARGS`; sets rc, out,
# status (the `cache:` lines) and why (the `re-evaluating:` line)
ev() {
  local b=$1; shift
  out=$(iets "$b" eval --impure --strict --timings "$@" 2>"$work/err"); rc=$?
  status=$(grep '^cache:' "$work/err" | tr '\n' ' ')
  why=$(grep '^re-evaluating:' "$work/err" | tr '\n' ' ' | sed 's/ $//')
}

main_nix() {
  write src/main.nix '{ a = import ./lib.nix; b = builtins.attrNames (builtins.readDir ./dir); c = builtins.getEnv "CACHETEST_VAR"; d = import <inc/x.nix>; }
'
  write src/lib.nix '40 + 2
'
  write src/dir/one 'x
'
  write inc1/x.nix '"inc1"
'
  write inc2/x.nix '"inc2"
'
  main=(-I "inc=$work/inc1" "$work/src/main.nix")
}

# cache_semantics.rs ----------------------------------------------------------
semantics() {
  local b=$1 tag=$2
  rm -rf "$work/cache" "$work/src" "$work/inc1" "$work/inc2"
  main_nix
  ev "$b" "${main[@]}"
  [ $rc = 0 ] && has "$status" "miss (no entry)" && has "$status" "wrote" && [ -z "$why" ]
  check "$tag hits_and_misses: a cold run misses and writes" $? "$status"
  first=$out
  ev "$b" "${main[@]}"
  has "$status" "cache: hit" && [ "$out" = "$first" ] && [ -z "$why" ]
  check "$tag hits_and_misses: the second run hits" $? "$status"
  write src/lib.nix '40 + 3
'
  ev "$b" "${main[@]}"
  local changed="re-evaluating: $work/src/lib.nix changed"
  has "$status" "miss (" && has "$status" "lib.nix changed" && has "$out" "a = 43" && [ "$why" = "$changed" ]
  check "$tag hits_and_misses: an edit misses and says what changed" $? "$status / $why"
  local same=0
  for _ in 1 2 3 4 5; do
    write src/lib.nix '40 + 4
'
    ev "$b" "${main[@]}"; [ "$why" = "$changed" ] || same=1
    write src/lib.nix '40 + 3
'
    ev "$b" "${main[@]}"; [ "$why" = "$changed" ] || same=1
  done
  check "$tag hits_and_misses: the same message whichever thread saw it" $same "$why"
  touch -d @946684800 "$work/src/lib.nix"
  ev "$b" "${main[@]}"
  has "$status" "cache: hit" && has "$status" " 1 rehashed"
  check "$tag hits_and_misses: a touch rehashes once" $? "$status"
  ev "$b" "${main[@]}"
  has "$status" "cache: hit" && has "$status" " 0 rehashed"
  check "$tag hits_and_misses: and then trusts the stat again" $? "$status"
  write src/dir/two 'y
'
  ev "$b" "${main[@]}"
  has "$status" "miss (" && has "$status" "directory" && has "$out" '"two"' &&
    [ "$why" = "re-evaluating: directory $work/src/dir has different entries" ]
  check "$tag hits_and_misses: a new directory entry misses" $? "$status / $why"
  CACHETEST_VAR=two ev "$b" "${main[@]}"
  has "$status" 'miss (environment variable $CACHETEST_VAR changed)' && has "$out" 'c = "two"' &&
    [ "$why" = 're-evaluating: environment variable $CACHETEST_VAR changed' ]
  check "$tag hits_and_misses: a variable misses" $? "$status / $why"
  ev "$b" "${main[@]}"
  has "$status" CACHETEST_VAR
  check "$tag hits_and_misses: one entry per key" $? "$status"
  ev "$b" -I "inc=$work/inc2" "$work/src/main.nix"
  has "$status" "miss (no entry)" && has "$out" 'd = "inc2"'
  check "$tag hits_and_misses: another search path is another key" $? "$status"
  write src/lib.nix 'throw "boom"
'
  ev "$b" "${main[@]}"
  [ $rc != 0 ] && ! has "$status" wrote
  check "$tag hits_and_misses: a failed run writes nothing" $? "$status"
  write src/lib.nix '1
'
  ev "$b" "${main[@]}"
  [ $rc = 0 ] && has "$status" "miss ("
  check "$tag hits_and_misses: and the fixed file is no stale hit" $? "$status"

  # a_copy_in_place_misses
  write ctime/main.nix 'import ./lib.nix
'
  write ctime/lib.nix '"AAAA"
'
  write ctime/other.nix '"BBBB"
'
  touch -d @1577836800 "$work/ctime/lib.nix" "$work/ctime/other.nix"
  ev "$b" --cache-dir "$work/ctimecache" "$work/ctime/main.nix"; local c1=$out
  cp -p "$work/ctime/other.nix" "$work/ctime/lib.nix"
  ev "$b" --cache-dir "$work/ctimecache" "$work/ctime/main.nix"
  [ "$c1" = '"AAAA"' ] && [ "$out" = '"BBBB"' ] && has "$status" "miss ("
  check "$tag a_copy_in_place_misses" $? "$c1 $out $status"

  # uncacheable_runs_write_nothing
  ev "$b" -E 'builtins.currentTime > 0'
  has "$status" "not written"
  check "$tag uncacheable_runs_write_nothing: currentTime" $? "$status"
  ev "$b" -E 'builtins.currentTime > 0'
  has "$status" "miss (no entry)"
  check "$tag uncacheable_runs_write_nothing: and the next run misses" $? "$status"
  ev "$b" -E '(builtins.tryEval (builtins.fetchTarball "https://x/y.tar.gz")).success'
  [ $rc != 0 ] && ! has "$status" wrote
  check "$tag uncacheable_runs_write_nothing: a fetch without a hash" $? "$status"

  # flags_that_turn_the_cache_off
  rm -rf "$work/cache"
  main_nix
  ev "$b" "${main[@]}"
  local before; before=$(cd "$work/cache" && find . -type f -printf '%p %T@ %s\n' | sort)
  ev "$b" --no-tracing-cache "${main[@]}"
  local quiet=$status
  ev "$b" --no-tracing-cache -E 'import /nonexistent/nocache-probe.nix'
  [ -z "$quiet" ] && [ "$(cd "$work/cache" && find . -type f -printf '%p %T@ %s\n' | sort)" = "$before" ]
  check "$tag flags_that_turn_the_cache_off: --no-tracing-cache touches nothing" $? "$quiet"
  EXTRA_ENV=IETS_CACHE=0 ev "$b" "${main[@]}"
  [ -z "$status" ]
  check "$tag flags_that_turn_the_cache_off: IETS_CACHE=0" $? "$status"
  local i=0 ok=0
  for case in ":1:1" "--no-tracing-cache:0:1" "--no-ir-cache:1:0" "--no-cache:0:0"; do
    IFS=: read -r flag t ir <<<"$case"
    # the IR cache holds files of at least IETS_IR_MIN bytes
    EXTRA_ENV=IETS_IR_MIN=0 ev "$b" --cache-dir "$work/stores$i" $flag "${main[@]}"
    [ $rc = 0 ] || ok=1
    [ "$( [ -e "$work/stores$i/trace" ] && echo 1 || echo 0)" = "$t" ] || ok=1
    [ "$( [ -e "$work/stores$i/ir" ] && echo 1 || echo 0)" = "$ir" ] || ok=1
    i=$((i + 1))
  done
  check "$tag flags_that_turn_the_cache_off: each flag turns off its store" $ok ""

  # a_lint_warning_is_replayed_on_a_hit
  write src/url.nix 'http://z.example
'
  ev "$b" --lint url-literal=warn "$work/src/url.nix"; local w1=$status
  ev "$b" --lint url-literal=warn "$work/src/url.nix"
  has "$w1" miss && has "$status" "cache: hit" && [ "$(grep -c '^warning: \[url-literal\]' "$work/err")" = 1 ]
  check "$tag a_lint_warning_is_replayed_on_a_hit" $? "$w1 / $status / $(cat "$work/err")"

  # lint/cli_cases.rs: the_scope_is_part_of_the_cache_key
  local url_warn='warning: [url-literal] URL literals are discouraged. Consider using a string literal "http://example.com" instead'
  ev "$b" --cache-dir "$work/scopecache" --lint url-literal=warn tests/lint/scope/root/main.nix
  local s1; s1=$(cat "$work/err")
  ev "$b" --cache-dir "$work/scopecache" --lint url-literal=warn --lint-scope all tests/lint/scope/root/main.nix
  ! has "$s1" "warning: [" && ! has "$status" "cache: hit" && has "$(cat "$work/err")" "scope/lib/url.nix:1:1"
  check "$tag lint: the scope is part of the cache key" $? "$s1 / $(cat "$work/err")"

  # lint/cli_cases.rs: an_allow_comment_is_part_of_the_cache_key_and_a_hit_replays_nothing
  mkdir -p "$work/allow"
  cp tests/lint/allow/own-line.nix "$work/allow/main.nix"
  ev "$b" --cache-dir "$work/allowcache" --lint url-literal=warn "$work/allow/main.nix"; local a1; a1=$(cat "$work/err")
  ev "$b" --cache-dir "$work/allowcache" --lint url-literal=warn "$work/allow/main.nix"; local a2=$status a2e; a2e=$(cat "$work/err")
  printf 'http://example.com\n' > "$work/allow/main.nix"
  ev "$b" --cache-dir "$work/allowcache" --lint url-literal=warn "$work/allow/main.nix"
  has "$a2" "cache: hit" && ! has "$a1" "warning: [" && ! has "$a2e" "warning: [" && ! has "$status" "cache: hit" &&
    has "$(cat "$work/err")" "$url_warn"
  check "$tag lint: an allow comment is part of the entry, and a hit replays nothing" $? "$a2 / $status"

  # the_file_argument_keeps_one_entry
  write key/top.nix 'import ./dep.nix
'
  write key/dep.nix '41 + 1
'
  ev "$b" --cache-dir "$work/keycache" "$work/key/top.nix"
  has "$status" "miss (no entry)" && [ -z "$why" ]
  check "$tag the_file_argument_keeps_one_entry: miss" $? "$status"
  ev "$b" --cache-dir "$work/keycache" "$work/key/top.nix"
  has "$status" "cache: hit"
  check "$tag the_file_argument_keeps_one_entry: hit" $? "$status"
  write key/top.nix 'import ./dep.nix # edited
'
  ev "$b" --cache-dir "$work/keycache" "$work/key/top.nix"
  [ "$why" = "re-evaluating: $work/key/top.nix changed" ]
  check "$tag the_file_argument_keeps_one_entry: an edit names the file" $? "$why"
  ev "$b" --cache-dir "$work/keycache" "$work/key/top.nix"
  has "$status" "cache: hit" && [ "$(find "$work/keycache/trace" -mindepth 1 -maxdepth 1 -type d | wc -l)" = 1 ]
  check "$tag the_file_argument_keeps_one_entry: one entry" $? "$status"
  rm "$work/key/top.nix"
  ev "$b" --cache-dir "$work/keycache" "$work/key/top.nix"
  [ $rc != 0 ] && [ "$why" = "re-evaluating: $work/key/top.nix is gone" ]
  check "$tag the_file_argument_keeps_one_entry: a removed file is gone" $? "$why"

  # the_cache_dir_keeps_what_it_did_not_make
  write mine/unrelated.txt 'PRECIOUS
'
  ev "$b" --cache-dir "$work/mine" -E 2
  [ $rc = 0 ] && [ "$(cat "$work/mine/unrelated.txt")" = PRECIOUS ] && [ -e "$work/mine/trace" ] && [ -e "$work/mine/ir" ]
  check "$tag the_cache_dir_keeps_what_it_did_not_make: its own stores" $? ""
  write theirs/trace/notes.txt 'PRECIOUS
'
  local err
  err=$(iets "$b" eval --strict --timings --cache-dir "$work/theirs" -E 2 2>&1 >/dev/null); rc=$?
  [ $rc = 0 ] && has "$err" "is not an iets cache" && [ "$(cat "$work/theirs/trace/notes.txt")" = PRECIOUS ]
  check "$tag the_cache_dir_keeps_what_it_did_not_make: a foreign directory is refused" $? "$err"
  err=$(iets "$b" cache gc --cache-dir "$work/ttl" --ttl 213503982334602 2>&1); rc=$?
  [ $rc = 2 ] && has "$err" "--ttl wants a number of days"
  check "$tag the_cache_dir_keeps_what_it_did_not_make: --ttl must fit" $? "$err"

  # a_hit_prints_paths_and_positions_the_same
  local o1 o2
  o1=$(iets "$b" eval --strict tests/lang/eval-okay-getattrpos.nix 2>/dev/null)
  o2=$(iets "$b" eval --strict --timings tests/lang/eval-okay-getattrpos.nix 2>"$work/err")
  [ "$o1" = "$o2" ] && [ "$(grep -c 'cache: hit' "$work/err")" = 1 ]
  check "$tag a_hit_prints_paths_and_positions_the_same" $? "$o1 / $o2"
}

# cache_hygiene.rs: cache_gc_removes_entries_past_the_ttl ---------------------
hygiene() {
  local b=$1 tag=$2 d=$work/gc
  rm -rf "$d"
  for i in 1 2 3; do write "gc-src/f$i.nix" "$i
"; iets "$b" eval --cache-dir "$d" "$work/gc-src/f$i.nix" >/dev/null 2>&1; done
  # one IR entry: a source past the IR cache's smallest size
  write gc-src/big.nix "$(printf '# %.0s padding padding padding padding\n' $(seq 30))
1
"
  EXTRA_ENV=IETS_IR_MIN=0 iets "$b" eval --no-tracing-cache --cache-dir "$d" "$work/gc-src/big.nix" >/dev/null 2>&1
  local fresh dry done_
  fresh=$(iets "$b" cache gc --cache-dir "$d" --ttl 30)
  has "$fresh" "trace: 0 of 3 entries" && has "$fresh" "ir: 0 of 1 entries"
  check "$tag cache_gc: fresh entries stay" $? "$fresh"
  dry=$(iets "$b" cache gc --cache-dir "$d" --ttl 0 --dry-run)
  has "$dry" "3 of 3 entries" && has "$dry" "(dry run)" && [ "$(find "$d/trace" -name entry | wc -l)" = 3 ]
  check "$tag cache_gc: a dry run keeps everything" $? "$dry"
  done_=$(iets "$b" cache gc --cache-dir "$d" --ttl 0)
  has "$done_" "3 of 3 entries" && has "$done_" "1 of 1 entries" && [ "$(find "$d/trace" -name entry | wc -l)" = 0 ] &&
    [ -e "$d/trace/version" ] && [ "$(find "$d/ir" -type f -not -name version -not -name lock -not -name gc-stamp | wc -l)" = 0 ]
  check "$tag cache_gc: --ttl 0 removes every entry and the store stays usable" $? "$done_"
}

semantics "$bin" "$(basename "$(dirname "$(dirname "$bin")")")"
hygiene "$bin" "$(basename "$(dirname "$(dirname "$bin")")")"

# parity with the oracle ------------------------------------------------------
# The same steps, one binary after the other, each in its own cache
# directory: stdout, the exit code, the `cache:` lines without their timings
# and the `re-evaluating:` line must be the oracle's.
norm() { sed -E 's/[0-9]+\.[0-9]{3}s/T/g'; }
if [ -x "$oracle" ] && [ "$oracle" != "$bin" ]; then
  rm -rf "$work/cache" "$work/rcache" "$work/src" "$work/inc1" "$work/inc2"
  rcache="$work/rcache"
  main_nix
  # the first writer of a store sweeps it and says so: not a step to compare
  iets "$bin" eval --timings -E 1 >/dev/null 2>&1
  cache=$rcache iets "$oracle" eval --timings -E 1 >/dev/null 2>&1
  pstep=0
  parity() { # ARGS: one step on both binaries
    pstep=$((pstep + 1))
    ev "$bin" "$@"; local zo=$out zr=$rc zs zw=$why
    zs=$(printf '%s' "$status" | norm)
    cache=$rcache ev "$oracle" "$@"; local rs
    rs=$(printf '%s' "$status" | norm)
    [ "$zo" = "$out" ] && [ "$zr" = "$rc" ] && [ "$zs" = "$rs" ] && [ "$zw" = "$why" ]
    check "parity step $pstep: $*" $? "zig: $zr $zs $zw
rust: $rc $rs $why"
  }
  parity "${main[@]}"
  parity "${main[@]}"
  write src/lib.nix '40 + 3
'
  parity "${main[@]}"
  parity "${main[@]}"
  touch -d @946684800 "$work/src/lib.nix"
  parity "${main[@]}"
  write src/dir/two 'y
'
  parity "${main[@]}"
  CACHETEST_VAR=two parity "${main[@]}"
  parity -E 'builtins.currentTime > 0'
  parity -E '(builtins.tryEval (builtins.fetchTarball "https://x/y.tar.gz")).success'
  write src/url.nix 'http://z.example
'
  parity --lint url-literal=warn "$work/src/url.nix"
  parity --lint url-literal=warn "$work/src/url.nix"
  parity --json -E '{ a = builtins.readFile ./tests/lang/data; b = builtins.pathExists ./nope; c = builtins.readFileType ./tests; }'
  parity --json -E '{ a = builtins.readFile ./tests/lang/data; b = builtins.pathExists ./nope; c = builtins.readFileType ./tests; }'
  parity --raw -E '"${./tests/lang/data}"'
  parity --raw -E '"${./tests/lang/data}"'
  parity --raw -E 'builtins.path { path = ./tests/lang; filter = p: t: t != "directory"; }'
  parity --raw -E 'builtins.path { path = ./tests/lang; filter = p: t: t != "directory"; }'

  # `iets build`: a hit plans and builds from the entry's tables, with no
  # evaluation (needs the machine's nix-daemon)
  if [ -S /nix/var/nix/daemon-socket/socket ]; then
    write bld/data.txt 'hi
'
    write bld/d.nix 'derivation { name = "trace-build-test"; system = "x86_64-linux"; builder = "/bin/sh"; args = [ "-c" "echo ${./data.txt} > $out" ]; }
'
    for step in 1 2 3; do
      [ $step = 3 ] && write bld/data.txt 'ho
'
      zo=$(iets "$bin" build --timings -f "$work/bld/d.nix" 2>"$work/zerr"); zr=$?
      ro=$(cache=$rcache iets "$oracle" build --timings -f "$work/bld/d.nix" 2>"$work/rerr"); rr=$?
      zs=$(grep -E '^(cache|eval|re-evaluating):' "$work/zerr" | norm); rs=$(grep -E '^(cache|eval|re-evaluating):' "$work/rerr" | norm)
      [ "$zo" = "$ro" ] && [ "$zr" = "$rr" ] && [ "$zs" = "$rs" ]
      check "parity: build step $step" $? "zig: $zr $zo $zs
rust: $rr $ro $rs"
    done
  fi

  # the same steps leave the same entries: each binary's `cache dump` and
  # `cache paths` of its own entries, as sets (reads are recorded in
  # evaluation order, which is each binary's own), entries named by each
  # binary's key, and an env value's hash keyed by each store's own key
  entries() { # BIN DIR
    for e in "$2"/trace/*/entry; do
      { iets "$1" cache dump "$e" | sed -E 's/^(env [^ ]+) [0-9a-f]+$/\1 H/' | sort
        iets "$1" cache paths "$e" --json | jq -c 'sort_by(.path, .kind)'; } | md5sum
    done | sort
  }
  a=$(entries "$bin" "$work/cache"); b=$(cache=$rcache entries "$oracle" "$rcache")
  [ -n "$a" ] && [ "$a" = "$b" ]
  check "parity: the same steps leave the same entries" $? "zig:
$a
rust:
$b"
  a=$(iets "$bin" cache gc --dry-run --ttl 0 2>&1); b=$(cache=$rcache iets "$oracle" cache gc --dry-run --ttl 0 2>&1 | sed "s#^$rcache/#$work/cache/#")
  [ "$a" = "$b" ]
  check "parity: cache gc counts each binary's directory the same" $? "$a
$b"
  for args in "cache" "cache foo" "cache dum" "cache gc --bogus" "cache gc --ttl x" "cache dump" "cache dump /nonexistent" "cache paths a b"; do
    # shellcheck disable=SC2086
    a=$(iets "$bin" $args 2>&1; echo "rc $?"); b=$(iets "$oracle" $args 2>&1; echo "rc $?")
    [ "$a" = "$b" ]
    check "parity: iets $args" $? "$a
$b"
  done
fi

echo "$fails failed"
[ "$fails" = 0 ]
