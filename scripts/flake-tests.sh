#!/usr/bin/env bash
# The Rust integration tests of flakes and sources, against BIN (default the
# debug build): tests/pure.rs, the URL cases of tests/e2e_prefetch.rs
# (a_url, sparse_members, errors; an_expression needs a build dispatcher)
# and tests/e2e_flake.rs. As in tests/e2e, each Rust test function gets a
# nix-daemon of its own on a private store dir, and iets and the real nix
# both talk to it only; inputs are local git repos and file:// tarballs.
# A case that needs what BIN lacks (`iets build`, the tracing cache) prints
# `skip NAME why`. Run it on ../iets/target/release/iets too: both must
# pass. usage: scripts/flake-tests.sh [BIN]
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
bin=${1:-$here/zig-out/bin/iets}
bin=$(realpath "$bin")
rust_tests=$(cd "$here/../iets/tests" && pwd)
work=$(mktemp -d)
S=
S_pid=
cleanup() {
  store_stop
  chmod -R u+w "$work" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT
T=$work/tmp
mkdir -p "$T" "$work/nixbin"
# the classic name: `nix flake prefetch-inputs` is iets run as `nix`
ln -s "$bin" "$work/nixbin/nix"
nixlink=$work/nixbin/nix
fails=0
passes=0
skips=0

check() { # NAME CONDITION-RESULT TEXT
  if [ "$2" = 0 ]; then echo "ok   $1"; passes=$((passes + 1))
  else echo "FAIL $1"; printf '%s\n' "$3" | sed 's/^/     /' | head -20; fails=$((fails + 1)); fi
}
skip() { echo "skip $1 ($2)"; skips=$((skips + 1)); }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
# stdout and stderr of a command, and its status; out and err lose their
# trailing newlines, as tests/hermetic's stdout() does
run() { "$@" >"$T/out" 2>"$T/err"; rc=$?; out=$(<"$T/out"); err=$(<"$T/err"); }
last() { printf '%s\n' "$1" | tail -n "$2" | paste -sd'|' | sed 's/|/ | /g'; }
# the `@nix` records of --log-format internal-json, one JSON object a line
records() { printf '%s\n' "$1" | sed -n 's/^@nix //p' | jq -cR 'fromjson? // empty'; }
first_error() { printf '%s\n' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -m1 '^error: '; }
wr() { mkdir -p "$(dirname "$1")"; printf '%s' "$2" > "$1"; }
# git in REPO, with no config of the machine's (tests/e2e git)
g() {
  local repo=$1; shift
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=iets -c user.email=iets@example.com \
    -c init.defaultBranch=main -c commit.gpgsign=false -C "$repo" "$@" || echo "git $* failed in $repo" >&2
}
LOCK='{"nodes":{"root":{}},"root":"root","version":7}'
system="$(uname -m)-linux"

# tests/hermetic: only PATH and TMPDIR come through.
inherit=(PATH="$PATH")
[ -n "${TMPDIR:-}" ] && inherit+=(TMPDIR="$TMPDIR")
hermetic() { # HOME CMD...
  local home=$1; shift
  env -i "${inherit[@]}" IETS_COMPLETE_MS=0 IETS_PROGRESS=false HOME="$home" XDG_CACHE_HOME="$home/.cache" \
    XDG_CONFIG_DIRS=/nonexistent NIX_CONF_DIR=/nonexistent NIX_STORE_DIR=/nix/store "$@"
}

# What BIN has. The Zig port has no `iets build` and no tracing cache yet.
mkdir -p "$work/probe"
has_build=0; has_trace=0
hermetic "$work/probe" "$bin" build --help 2>&1 | grep -q 'iets build' && has_build=1
has "$(cd "$work/probe" && hermetic "$work/probe" "$bin" eval --timings --raw -E '"x"' 2>&1 >/dev/null)" "cache:" && has_trace=1
no_trace="BIN has no tracing cache"
no_build="BIN has no iets build"

# tests/e2e Store ------------------------------------------------------------
# Store::env: the hermetic environment, with the store, the daemon and the
# config of the store dir S.
senv() {
  env -i "${inherit[@]}" IETS_COMPLETE_MS=0 IETS_PROGRESS=false \
    NIX_STORE_DIR="$S/store" NIX_STATE_DIR="$S/var" NIX_LOG_DIR="$S/log" \
    NIX_DAEMON_SOCKET_PATH="$S/socket" NIX_CONF_DIR="$S/conf" NIX_USER_CONF_FILES= \
    XDG_CONFIG_HOME="$S/xdg" XDG_CONFIG_DIRS="$S/xdg" XDG_CACHE_HOME="$S/cache" HOME="$S" "$@"
}
store_start() {
  # a socket path has to fit in sun_path
  S=$(mktemp -d /tmp/iets-e2e.XXXXXX)
  mkdir -p "$S/store" "$S/var" "$S/log" "$S/conf" "$S/pkgs"
  echo '{"flakes":[],"version":2}' > "$S/conf/registry.json"
  printf 'experimental-features = nix-command flakes\nsubstituters =\ntrusted-users = *\nbuild-users-group =\nsandbox = false\nflake-registry = %s\n' \
    "$S/conf/registry.json" > "$S/conf/nix.conf"
  (cd "$S" && exec setsid env -i "${inherit[@]}" IETS_COMPLETE_MS=0 IETS_PROGRESS=false \
    NIX_STORE_DIR="$S/store" NIX_STATE_DIR="$S/var" NIX_LOG_DIR="$S/log" \
    NIX_DAEMON_SOCKET_PATH="$S/socket" NIX_CONF_DIR="$S/conf" NIX_USER_CONF_FILES= \
    XDG_CONFIG_HOME="$S/xdg" XDG_CONFIG_DIRS="$S/xdg" XDG_CACHE_HOME="$S/cache" HOME="$S" \
    nix-daemon --store local </dev/null >"$S/daemon.log" 2>&1) &
  S_pid=$!
  # tests/e2e/pkgs, with an env.nix that names this machine's bash and
  # coreutils and a nonce, so every Store builds fresh paths
  cp "$rust_tests"/e2e/pkgs/* "$S/pkgs/"
  local nonce coreutils
  nonce=$(date +%s%N)
  coreutils=$(dirname "$(realpath "$(command -v ls)")")
  printf '{ shell = "%s"; path = "%s"; system = "%s"; nonce = "%s"; }' \
    "$(realpath "$(command -v bash)")" "$coreutils" "$system" "$nonce" > "$S/pkgs/env.nix"
  local i=0
  while [ ! -S "$S/socket" ] && [ $i -lt 600 ]; do sleep 0.05; i=$((i + 1)); done
  [ -S "$S/socket" ] || { echo "no daemon socket: $(cat "$S/daemon.log")" >&2; exit 1; }
  mkdir -p "$S/nobin"
  nobin=$S/nobin
}
store_stop() {
  [ -n "$S_pid" ] && { kill -KILL -- "-$S_pid" 2>/dev/null; kill -KILL "$S_pid" 2>/dev/null; wait "$S_pid" 2>/dev/null; }
  [ -n "$S" ] && { chmod -R u+w "$S" 2>/dev/null; rm -rf "$S"; }
  S= S_pid=
}
# s.nix(): a Nix tool, talking to this daemon only; NIXCWD for current_dir
nixc() { (cd "${NIXCWD:-$S}" && senv NIX_REMOTE=daemon nix "$@"); }
# s.iets(): iets with this store's environment, in the store dir
siets() { (cd "$S" && senv "$@"); }
# F::iets(): the same with the cache in the store dir. Leading VAR=VAL
# arguments add to the environment, then the command.
fenv() { (cd "$S" && senv IETS_CACHE_DIR="$S/cache" "$@"); }

# pure.rs --------------------------------------------------------------------
# A project holding repo/read.nix, which reads repo/in.txt, and outside.txt
# beside the project; the marker is an iets.toml.
checkout() {
  D=$(mktemp -d "$work/pure.XXXXXX"); H=$(mktemp -d "$work/home.XXXXXX")
  repo=$D/repo; mkdir -p "$repo"
  : > "$repo/iets.toml"
  printf out > "$D/outside.txt"; printf in > "$repo/in.txt"
  printf 'builtins.readFile ./in.txt' > "$repo/read.nix"
  printf 'builtins.readFile ../outside.txt' > "$repo/up.nix"
  printf 'builtins.getEnv "IETS_TEST_VAR"' > "$repo/env.nix"
}
# leading VAR=VAL arguments add to the environment, then the command
prun() { (cd "$repo" && hermetic "$H" IETS_CACHE=0 "$@"); }

checkout
run prun "$bin" eval --raw -f read.nix
[ $rc = 0 ] && [ "$out" = in ]
check "pure: a read in the project is pure" $? "$rc $out $err"
run prun "$bin" eval --raw -f up.nix
[ $rc = 1 ] && has "$err" "outside.txt' is forbidden in pure evaluation mode"
check "pure: a read above the project is not" $? "$rc $out $err"
run prun "$bin" eval --raw --impure -f up.nix
[ $rc = 0 ] && [ "$out" = out ]
check "pure: --impure reads above the project" $? "$rc $out $err"

for c in "file_link|builtins.readFile ./file-link" "dir_link|builtins.readFile ./dir-link/outside.txt" \
  "import_link|import ./nix-link" "home_dots|builtins.readFile ~/repo/../outside.txt" \
  "path_exists|if builtins.pathExists ./dir-link/outside.txt then \"\" else 0"; do
  name=${c%%|*}; expr=${c#*|}
  checkout
  echo 1 > "$D/outside.nix"
  ln -s ../outside.txt "$repo/file-link"; ln -s .. "$repo/dir-link"; ln -s ../outside.nix "$repo/nix-link"
  printf '%s' "$expr" > "$repo/e.nix"
  run prun HOME="$D" "$bin" eval --raw -f e.nix
  if [ "$name" = path_exists ]; then has "$err" "cannot coerce an integer"
  else [ $rc = 1 ] && has "$err" "is forbidden in pure evaluation mode"; fi
  check "pure: a link out of the project is forbidden ($name)" $? "$rc $out $err"
done

checkout
rm "$repo/iets.toml"
run prun "$bin" eval --raw -f read.nix
[ $rc = 0 ] && [ "$out" = in ]
check "pure: a directory with no marker is its own project" $? "$rc $out $err"

checkout
run prun "$bin" eval --raw -f env.nix
[ $rc = 0 ] && [ -z "$out" ]
r1=$?
run prun "$bin" eval -E "builtins ? currentSystem"
[ $r1 = 0 ] && [ "$out" = false ]
check "pure: the other purity rules hold without a flag" $? "$rc $out $err"

checkout
mkdir -p "$D/config/iets"
echo 'pure = false' > "$D/config/iets/iets.toml"
run prun XDG_CONFIG_HOME="$D/config" "$bin" eval --raw -f up.nix
[ $rc = 0 ] && [ "$out" = out ]
check "pure: the user's file turns pure off" $? "$rc $out $err"
echo 'pure = false' > "$repo/iets.toml"
run prun "$bin" eval --raw -f read.nix
[ $rc = 1 ] && has "$err" "'pure' may not be set in a project file"
check "pure: a project's file may not set pure" $? "$rc $out $err"

# get_flake_takes_a_path_its_nar_hash_locks
D=$(mktemp -d "$work/pure.XXXXXX"); H=$(mktemp -d "$work/home.XXXXXX"); repo=$D
printf '{ outputs = _: { x = 42; }; }' > "$D/flake.nix"
printf '%s' "$LOCK" > "$D/flake.lock"
run prun "$bin" eval --impure --raw --expr "(builtins.fetchTree { type = \"path\"; path = \"$D\"; }).narHash"
hash=$out
[ $rc = 0 ] && [ -n "$hash" ]
check "pure: fetchTree of a path has a narHash" $? "$rc $out $err"
run prun "$bin" eval --expr "(builtins.getFlake \"path:$D?narHash=$hash\").x"
[ $rc = 0 ] && [ "$(od -An -c "$T/out" | tr -d ' ')" = '42\n' ]
check "pure: getFlake takes a path its narHash locks" $? "$rc $out $err"
run prun "$bin" eval --expr "(builtins.getFlake \"path:$D?narHash=sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\").x"
[ $rc = 1 ] && has "$err" "NAR hash mismatch"
check "pure: getFlake refuses a tree its narHash does not lock" $? "$rc $out $err"
run prun "$bin" eval --expr "(builtins.getFlake \"path:$D\").x"
has "$err" "unlocked flake reference"
check "pure: getFlake refuses a path with no narHash" $? "$rc $out $err"
run prun "$bin" eval --expr "builtins.fetchTree { type = \"path\"; path = \"$D\"; narHash = true; }"
[ $rc = 1 ] && has "$err" "input attribute 'narHash' is not a string"
check "pure: a narHash that is not a string" $? "$rc $out $err"

# e2e_prefetch.rs ------------------------------------------------------------
prefetched() { nixc store prefetch-file --json "$@" | jq -r .hash; }
nix_hash() { nixc hash "$@"; }
prefetch() { siets "$bin" prefetch "$@" 2>/dev/null; }
# src.tar.gz of a small tree
tarball() {
  wr "$S/src/a.txt" $'hello\n'; wr "$S/src/sub/b.txt" $'sub\n'
  tar -czf "$S/src.tar.gz" -C "$S" src
  tarpath=$S/src.tar.gz; url=file://$tarpath
}

store_start
tarball
flat=$(prefetch "$url")
[ -n "$flat" ] && [ "$flat" = "$(prefetched "$url")" ] && [ "$flat" = "$(nix_hash file --sri "$tarpath")" ]
check "prefetch/a_url: flat" $? "iets $flat nix $(prefetched "$url")"
unpacked=$(prefetch --unpack "$url")
[ -n "$unpacked" ] && [ "$unpacked" = "$(prefetched --unpack "$url")" ]
check "prefetch/a_url: --unpack" $? "iets $unpacked nix $(prefetched --unpack "$url")"
run siets "$bin" prefetch --json --unpack "$url"
[ $rc = 0 ] && [ "$(jq -cS . <<<"$out")" = "$(jq -cnS --arg h "$unpacked" --arg u "$url" '{hash: $h, url: $u}')" ]
check "prefetch/a_url: --json" $? "$out $err"
sha512=$(prefetch --hash-type sha512 "$url")
[ -n "$sha512" ] && [ "$sha512" = "$(nix_hash file --sri --type sha512 "$tarpath")" ]
check "prefetch/a_url: --hash-type sha512" $? "iets $sha512 nix $(nix_hash file --sri --type sha512 "$tarpath")"
skip "prefetch/an_expression" "run by Rust's own e2e_prefetch.rs through scripts/rust-tests.sh"
store_stop

store_start
mkdir -p "$S/sp/top"
truncate -s 4194304 "$S/sp/top/hole"
printf 'end\n' >> "$S/sp/top/hole"
for form in "gnu|--format=gnu" "pax0.0|--format=posix --sparse-version=0.0" \
  "pax0.1|--format=posix --sparse-version=0.1" "pax1.0|--format=posix --sparse-version=1.0"; do
  tag=${form%%|*}; read -ra targs <<<"${form#*|}"
  tar -S "${targs[@]}" -cf "$S/sp-$tag.tar" -C "$S/sp" top
  ours=$(prefetch --unpack "file://$S/sp-$tag.tar"); theirs=$(prefetched --unpack "file://$S/sp-$tag.tar")
  [ -n "$ours" ] && [ "$ours" = "$theirs" ]
  check "prefetch/sparse_members: $tag" $? "iets $ours nix $theirs"
done
# the archive is 10 KiB and the file it names 4 MiB: the cap counts the
# bytes the expansion writes
run siets "$bin" prefetch --unpack --iets-option fetch-max-size 1048576 "file://$S/sp-gnu.tar"
[ $rc != 0 ] && has "$err" fetch-max-size
check "prefetch/sparse_members: fetch-max-size caps the expansion" $? "$rc $err"
store_stop

store_start
tarball
codes=""
for a in "--bogus" "--hash-type sha7 $url" "--unpack -E 1" "file://$S/nothing.tar.gz"; do
  read -ra args <<<"$a"
  siets "$bin" prefetch "${args[@]}" >/dev/null 2>&1
  codes="$codes $?"
done
[ "$codes" = " 2 2 2 1" ]
check "prefetch/errors: exit codes" $? "codes$codes, want 2 2 2 1"
store_stop

# e2e_flake.rs ---------------------------------------------------------------
F="e2e_flake"
nix_eval() { run nixc eval --raw --option eval-cache false "$1"; }
# Both evaluators agree and succeed. NAME REF [VAR=VAL...]
fcheck() {
  local name=$1 r=$2; shift 2
  nix_eval "$r"; local exp=$out nerr=$err
  run fenv "$@" "$bin" eval --raw --no-tracing-cache "$r"
  [ -n "$exp" ] && [ "$exp" = "$out" ]
  check "$name" $? "nix:  $exp $(last "$nerr" 3)
iets: $out $(last "$err" 3)"
}
# fcheck on a tree Nix never copied: iets runs first, with the cache off,
# and fetches nothing
check_fresh() {
  local name=$1 r=$2
  run fenv IETS_CACHE=0 "$bin" eval --raw --no-cache "$r"; local got=$out ierr=$err
  nix_eval "$r"
  [ -n "$out" ] && [ "$out" = "$got" ] && ! has "$ierr" fetching
  check "$name" $? "nix:  $out
iets: $got $(last "$ierr" 3)"
}
# Both refuse, with the same error: line and status. The provenance
# rewrite is off, so the message names the store path as Nix does.
check_error() {
  local name=$1 r=$2
  nix_eval "$r"; local exp nrc=$rc
  exp=$(first_error "$err")
  run fenv IETS_PROVENANCE=0 "$bin" eval --raw --no-tracing-cache --pure-eval "$r"
  local got; got=$(first_error "$err")
  [ -n "$exp" ] && [ "$exp" = "$got" ] && [ $nrc = $rc ]
  check "$name" $? "nix:  $exp ($nrc)
iets: $got ($rc)"
}
# iets alone, with no nix, fetches the input and prints EXPECTED
fetch_only() {
  local name=$1 r=$2 expected=$3
  run fenv IETS_NIX_BIN_DIR="$nobin" PATH="$nobin" "$bin" eval --raw --no-tracing-cache "$r"
  [ -n "$expected" ] && [ "$out" = "$expected" ] && has "$err" "fetching it"
  check "$name" $? "want: $expected
iets: $out $(last "$err" 3)"
}
# Nix locks the flake at DIR and evaluates DIR#v in a store of its own;
# sets exp to that value and inpath to the store path of INPUT
lock_apart() {
  local dir=$1 input=$2 store=$S/$3
  run nlock "$dir" --store "$store"
  [ $rc = 0 ] || echo "lock $dir: $(last "$err" 3)" >&2
  exp=$(nixc eval --store "$store" --raw --option eval-cache false "$dir#v" 2>/dev/null)
  inpath=$(nixc eval --store "$store" --raw --impure --expr "(builtins.getFlake \"$dir\").inputs.$input.outPath" 2>/dev/null)
}
# nix flake lock in DIR
nlock() { (NIXCWD=$1; shift; nixc flake lock "$@"); }
cache_lines() { fenv "$bin" eval --raw --timings "$1" 2>&1 >/dev/null | grep '^cache:'; }
nar_hash() { nixc hash path --type sha256 --sri "$1"; }
lib_repo() {
  lib=$S/lib
  wr "$lib/flake.nix" $'{ outputs = { self }: { greeting = "hello-" + self.shortRev; }; }\n'
  g "$lib" init -q; g "$lib" add -A; g "$lib" commit -q -m lib
}
sub_flake() { wr "$S/sub/flake.nix" $'{ outputs = { self }: { value = "sub-" + self.narHash; }; }\n'; }
tgz() { tar -C "$1" -czf "$2" "$3"; } # DIR OUT MEMBER
# a lock with tarball inputs that are not flakes: NAME URL HASH ...
tarball_lock() {
  jq -cn --args '$ARGS.positional as $p | [range(0; $p | length; 3) as $k | $p[$k:$k + 3]] as $i | {nodes: (($i | map({key: .[0], value: {flake: false,
    locked: {type: "tarball", url: .[1], narHash: .[2]}, original: {type: "tarball", url: .[1]}}}) | from_entries)
    + {root: {inputs: ($i | map({key: .[0], value: .[0]}) | from_entries)}}), root: "root", version: 7}' "$@"
}

# inputs_of_every_type: locked inputs of every offline type
store_start
N="$F/inputs_of_every_type"
lib_repo
wr "$S/util/flake.nix" "{
  inputs.lib.url = \"git+file://$lib\";
  outputs = { self, lib }: { twice = lib.greeting + lib.greeting; inherit lib; };
}
"
wr "$S/tbsrc/flake.nix" "{ outputs = { self }: { value = \"tarball-\" + self.narHash; }; }
# $S/
"
tgz "$S" "$S/tb.tar.gz" tbsrc
big=$S/big
wr "$big/flake.nix" "{
  inputs.pkgs.url = \"path:$S/pkgs\";
  inputs.lib.url = \"git+file://$lib\";
  inputs.util.url = \"path:$S/util\";
  inputs.util.inputs.lib.follows = \"lib\";
  inputs.tb.url = \"file://$S/tb.tar.gz\";
  outputs = { self, pkgs, lib, util, tb }:
    let
      system = \"x86_64-linux\";
      chain = builtins.head (builtins.attrValues pkgs.packages);
    in {
      devShells.\${system}.default = derivation {
        name = \"shell\"; inherit system; builder = \"/bin/sh\"; deps = [ chain.chain ];
        GREETING = util.twice + \" \" + tb.value + \" \" + lib.greeting;
      };
    };
}
"
run nlock "$big"
check "$N: nix flake lock" $rc "$err"
shell="$big#devShells.x86_64-linux.default.drvPath"
fcheck "$N: big: devShell" "$shell"
fcheck "$N: big: devShell, IETS_WORKERS=8" "$shell" IETS_WORKERS=8
# an input's metadata is silent until the input has a level of its own;
# the site is the binding in the root flake
quiet=$(fenv "$bin" eval --raw --no-tracing-cache "$shell" 2>&1 >/dev/null)
wr "$big/iets.toml" $'[lint.inputs.lib]\ntree-meta-in-drv = "warn"\n'
loud=$(fenv "$bin" eval --raw --no-tracing-cache "$shell" 2>&1 >/dev/null)
line=$(grep -n GREETING "$big/flake.nix" | head -1 | cut -d: -f1)
! has "$quiet" tree-meta-in-drv &&
  has "$loud" "attribute 'GREETING' holds 'inputs.lib.shortRev', a value that changes with every update of the lock file" &&
  has "$loud" "at $big/flake.nix:$line:"
check "$N: tree-meta, input" $? "$quiet | $loud"
store_stop

# a_git_working_tree: a git flake with a path: input, a relative path:
# input and a follows, in every state a working tree can be in
store_start
N="$F/a_git_working_tree"
sub_flake
wr "$S/dep/flake.nix" "{
  inputs.sub.url = \"path:$S/sub\";
  outputs = { self, sub }: { value = \"dep-\" + sub.value; inherit sub; };
}
"
r=$S/repo
scratch_nix=$(cat <<'EOF'
{
  inputs.sub.url = "path:@WORK@/sub";
  inputs.dep.url = "path:@WORK@/dep";
  inputs.dep.inputs.sub.follows = "sub";
  inputs.rel.url = "path:./rel";
  outputs = { self, dep, sub, rel }: {
    packages.x86_64-linux.default = derivation {
      name = "scratch";
      system = "x86_64-linux";
      builder = "/bin/sh";
      args = [ "-c" "echo ${self.narHash} ${self.rev or self.dirtyRev or "norev"} ${self.shortRev or self.dirtyShortRev or "norev"} ${toString self.lastModified} ${self.lastModifiedDate} ${toString (self.revCount or 0)} ${dep.value} ${dep.sub.value} ${dep.outPath} ${sub.outPath} ${rel.value} ${rel.outPath} ${self}/file ${builtins.readFile (self + "/file")} ${toString (builtins.attrNames (builtins.readDir self))} ${toString (builtins.pathExists (self + "/untracked"))} ${import ./nested/lib.nix} ${./nested} > $out" ];
    };
    visible = builtins.toJSON {
      context = builtins.getContext "${self.narHash} ${self.lastModifiedDate}";
      has = builtins.hasContext (builtins.substring 0 8 self.lastModifiedDate);
      equal = self.narHash == builtins.unsafeDiscardStringContext self.narHash;
      json = builtins.toJSON { inherit (self) narHash lastModifiedDate; };
      name = { ${self.lastModifiedDate} = builtins.replaceStrings [ "-" ] [ "+" ] self.narHash; };
      file = builtins.toFile "meta" self.narHash;
    };
  };
}
EOF
)
wr "$r/flake.nix" "${scratch_nix//@WORK@/$S}
"
wr "$r/file" $'one\n'
wr "$r/nested/tracked" $'two\n'
wr "$r/nested/lib.nix" $'"lib"\n'
wr "$r/rel/flake.nix" $'{ outputs = { self }: { value = "rel-" + builtins.readFile (self + "/data"); }; }\n'
wr "$r/rel/data" reldata
g "$r" init -q; g "$r" add -A; g "$r" commit -q -m init
nlock "$r" >/dev/null 2>&1
g "$r" add flake.lock; g "$r" commit -q -m lock
scratch="$r#packages.x86_64-linux.default"
drv="$scratch.drvPath"
# Nix writes a relative path node without a narHash
rel=$(jq -cS .nodes.rel.locked "$r/flake.lock")
[ "$rel" = '{"path":"./rel","type":"path"}' ]
check "$N: lock: rel has no narHash" $? "rel is $rel"
# a worktree at a path nix never copied: the root tree is never fetched
fresh=$S/fresh
g "$r" worktree add -q "$fresh" HEAD
wr "$fresh/untracked" $'untracked\n'
check_fresh "$N: worktree: clean tree nix never saw" "$fresh#packages.x86_64-linux.default.drvPath"
rev=$(g "$fresh" rev-parse HEAD)
pinned="git+file://$fresh?ref=HEAD&rev=$rev#packages.x86_64-linux.default.drvPath"
fcheck "$N: worktree: pinned by rev" "$pinned"
wr "$fresh/file" $'changed\n'
check_fresh "$N: worktree: dirty tree nix never saw" "$fresh#packages.x86_64-linux.default.drvPath"
fcheck "$N: worktree: dirty tree, pinned rev is still the commit" "$pinned"
g "$r" worktree remove --force "$fresh"
fcheck "$N: scratch: clean tree" "$drv"
fcheck "$N: scratch: tree metadata strings have no context" "$r#visible"
fcheck "$N: scratch: --raw on a derivation prints its outPath" "$scratch"
wr "$r/untracked" $'untracked\n'
fcheck "$N: scratch: an untracked file is ignored" "$drv"
# reading an untracked file is Nix's error, and the hint is the git add
u=$S/untracked
wr "$u/flake.nix" '{ outputs = _: { v = builtins.readFile ./extra; }; }'
wr "$u/flake.lock" "$LOCK"
wr "$u/extra" $'x\n'
g "$u" init -q; g "$u" add flake.nix flake.lock
line="Path 'extra' in the repository \"$u\" is not tracked by Git."
run nixc eval --raw "$u#v"; nrc=$rc nerr=$err
run fenv "$bin" eval --raw --no-tracing-cache --log-format internal-json "$u#v"
rec=$(records "$err" | jq -c 'select(.level == 0)' | head -1)
[ $nrc = 1 ] && has "$nerr" "$line" && [ $rc = 1 ] &&
  [ "$(jq -r '.raw_msg // "" | startswith($l)' --arg l "$line" <<<"${rec:-null}")" = true ] &&
  [ "$(jq -r '.hint // ""' <<<"${rec:-null}")" = "run 'git -C \"$u\" add \"extra\"'" ]
check "$N: untracked read" $? "nix $nrc; iets $rc: ${rec:-$(last "$err" 3)}"
wr "$r/file" $'three\n'
fcheck "$N: scratch: dirty tree (modified tracked file)" "$drv"
held=$(fenv "$bin" eval --raw --no-tracing-cache "$drv" 2>&1 >/dev/null)
has "$held" "holds 'self.dirtyRev', 'self.dirtyShortRev', 'self.lastModifiedDate', 'self.narHash'"
check "$N: tree-meta, dirty" $? "$held"
rm "$r/nested/tracked"
fcheck "$N: scratch: dirty tree (deleted tracked file)" "$drv"
wr "$r/added" $'four\n'
g "$r" add added
fcheck "$N: scratch: dirty tree (staged new file)" "$drv"
g "$r" commit -q -am next
fcheck "$N: scratch: clean again after commit" "$drv"
held=$(fenv "$bin" eval --raw --no-tracing-cache "$drv" 2>&1 >/dev/null)
has "$held" "[tree-meta-in-drv] derivation 'scratch': attribute 'args' holds 'self.lastModifiedDate', 'self.narHash', 'self.rev', 'self.shortRev'"
check "$N: tree-meta, clean" $? "$held"
fcheck "$N: scratch: subdirectory ref" "$r/.#packages.x86_64-linux.default.drvPath"
fcheck "$N: scratch: path: copies the whole tree" "path:$r#packages.x86_64-linux.default.drvPath"
nixc eval --json --option eval-cache false "$drv" > "$T/exp" 2>/dev/null
fenv "$bin" eval --json --no-tracing-cache "$drv" > "$T/got" 2>/dev/null
[ -s "$T/exp" ] && cmp -s "$T/exp" "$T/got"
check "$N: scratch: --json" $? "nix:  $(cat "$T/exp")
iets: $(cat "$T/got")"
# tracing cache: a hit after a miss, a miss after the tree changes
if [ $has_trace = 1 ]; then
  fenv "$bin" eval --raw "$drv" >/dev/null 2>&1
  st=$(cache_lines "$drv")
  has "$st" "cache: hit"
  check "$N: cache: second run" $? "$st"
  # the date and the count follow from the revision: a validation starts no
  # git log and no git rev-list
  cmds=$(for e in "$S"/cache/trace/*/entry; do
    [ -e "$e" ] || continue
    fenv "$bin" cache dump "$e" 2>/dev/null | while IFS= read -r l; do
      case "$l" in "cmd $r "*) set -- ${l#"cmd $r "}; shift
        for w in "$@"; do case "$w" in -*) ;; *) echo "$w"; break ;; esac; done ;; esac
    done
  done | sort -u | paste -sd' ')
  [ "$cmds" = "ls-files rev-parse status" ]
  check "$N: cache: git observations" $? "$cmds"
else
  skip "$N: cache: second run" "$no_trace"
  skip "$N: cache: git observations" "$no_trace"
fi
wr "$r/file" $'five\n'
if [ $has_trace = 1 ]; then
  st=$(cache_lines "$drv"); has "$st" "miss ("
  check "$N: cache: edit misses" $? "$st"
else skip "$N: cache: edit misses" "$no_trace"; fi
g "$r" commit -q -am five
if [ $has_trace = 1 ]; then
  st=$(cache_lines "$drv"); has "$st" "miss (" && has "$st" git
  check "$N: cache: a commit misses on git" $? "$st"
else skip "$N: cache: a commit misses on git" "$no_trace"; fi
rm "$r/flake.lock"
err=$(fenv "$bin" eval --raw --no-tracing-cache "$drv" 2>&1 >/dev/null)
has "$err" "flake.lock missing or incomplete, run nix flake lock"
check "$N: missing flake.lock" $? "$err"
store_stop

# rev_count: revCount is there when Nix has it, and counted only when read
store_start
N="$F/rev_count"
wr "$S/reader/flake.nix" $'{ outputs = { self }: { count = t: t.revCount; }; }\n'
c=$S/count
count_nix=$(cat <<'EOF'
{
  inputs.reader.url = "path:@WORK@/reader";
  outputs = { self, reader }:
    let
      s = self;
      f = { self, ... }: self.revCount;
      info = removeAttrs self.sourceInfo [ "outPath" "submodules" ];
      name = "rev" + "Count";
    in {
    meta = builtins.toJSON {
      count = self.revCount or null;
      has = self ? revCount;
      names = builtins.attrNames self.sourceInfo;
      date = self.lastModified;
    };
    names = builtins.toJSON [ (self ? revCount) (builtins.attrNames self) (let n = self.revCount; in 1) ];
    again = toString self.revCount;
    twice = toString (self.revCount + self.sourceInfo.revCount);
    site = {
      select = toString self.revCount;
      default = toString (self.revCount or 0);
      inherited = toString { inherit (self) revCount; }.revCount;
      info = toString self.sourceInfo.revCount;
      bound = toString s.revCount;
      argument = toString (f { inherit self; });
      builtin = toString (builtins.getAttr "revCount" self);
      input = toString (reader.count self);
    };
    forced = {
      json = builtins.toJSON info;
      values = toString (builtins.attrValues info);
      computed = toString self.${name};
      mapped = toString (builtins.mapAttrs (n: v: v) info).revCount;
      scope = with self; toString revCount;
    };
    silent = {
      allowed = toString self.revCount; # iets: allow rev-count
      other = toString { revCount = 2; }.revCount;
      whole = builtins.toJSON self;
    };
    all = builtins.toJSON [ self.site self.forced self.silent ];
  };
}
EOF
)
wr "$c/flake.nix" "${count_nix//@WORK@/$S}
"
nlock "$c" >/dev/null 2>&1
g "$c" init -q; g "$c" add -A; g "$c" commit -q -m one
g "$c" commit -q --allow-empty -m two
fcheck "$N: revCount: clean tree" "$c#meta"
shallow=$S/count-shallow
g "$S" clone -q --depth 1 "file://$c" "$shallow"
fcheck "$N: revCount: shallow clone" "$shallow#meta"
# git rev-list fails here: a run that does not read the count starts none,
# and one that reads it takes the count the store kept
wr "$S/nolist/git" "#!/bin/sh
case \"\$1\" in rev-list) exit 9 ;; esac
exec $(command -v git) \"\$@\"
"
chmod 755 "$S/nolist/git"
nolistpath="$S/nolist:$PATH"
run fenv PATH="$nolistpath" "$bin" eval --raw --no-tracing-cache "$c#names"; lazy_rc=$rc lazy_out=$out lazy_err=$err
run fenv PATH="$nolistpath" "$bin" eval --raw --no-tracing-cache "$c#again"; none_rc=$rc none_err=$err
[ $lazy_rc = 0 ] && [[ $lazy_out == "[true,"* ]] && [ $none_rc = 1 ] && has "$none_err" '`git rev-list --count'
check "$N: revCount lazy" $? "$lazy_out / $(last "$none_err" 2)"
# the count kept is the tracing cache's: the run without rev-list is a hit
fenv "$bin" eval --raw "$c#meta" >/dev/null 2>&1
if [ $has_trace = 1 ]; then
  run fenv PATH="$nolistpath" "$bin" eval --raw "$c#again"
  [ $rc = 0 ] && [ "$out" = 2 ]
  check "$N: revCount lazy, the count kept" $? "$(last "$err" 2) ($out)"
else skip "$N: revCount lazy, the count kept" "$no_trace"; fi
# one finding per tree, with its site, from a cache hit too
finding="[rev-count] 'self.revCount' is deprecated: the count of all revisions is expensive to compute"
lints() { records "$1" | jq -c --arg f "$finding" 'select(.code == "lint" and ((.raw_msg // "") | startswith($f)))'; }
if [ $has_trace = 1 ]; then
  cargs=(--raw --timings --log-format internal-json --cache-dir "$S/count-cache" "$c#twice")
  run fenv "$bin" eval "${cargs[@]}"; o1=$out; l1=$(lints "$err")
  run fenv "$bin" eval "${cargs[@]}"; o2=$out; l2=$(lints "$err")
  s1=$(jq -c .start <<<"$l1" 2>/dev/null); s2=$(jq -c .start <<<"$l2" 2>/dev/null)
  [ "$o1" = 4 ] && [ "$o2" = 4 ] && [ "$(grep -c . <<<"$l1")" = 1 ] && [ "$(grep -c . <<<"$l2")" = 1 ] &&
    [ "$s1" != null ] && [ "$s1" = "$s2" ] && has "$err" "cache: hit" && ! has "$lazy_err" rev-count
  check "$N: rev-count findings" $? "$l1 | $l2"
else skip "$N: rev-count findings" "$no_trace (the second run must be a cache hit)"; fi
run fenv "$bin" eval --raw --no-tracing-cache --lint rev-count=error "$c#again"
[ $rc = 1 ] && [[ $err == "error: $finding"* ]]
check "$N: rev-count=error" $? "$err"
# a selection of the count is the site, in an input's code too
covered() {
  run fenv "$bin" eval --raw --no-tracing-cache --log-format internal-json "$c#$1"
  local recs n start end line file
  recs=$(lints "$err"); n=$(grep -c . <<<"$recs")
  if [ $rc != 0 ] || [ "$n" != 1 ]; then echo "exit $rc, $n findings"; return; fi
  start=$(jq -r '.start | numbers' <<<"$recs"); end=$(jq -r '.end | numbers' <<<"$recs")
  line=$(jq -r '.line // empty' <<<"$recs")
  if [ -z "$start" ] || [ -z "$end" ] || [ -z "$line" ]; then echo "no site"; return; fi
  file=$(jq -r .file <<<"$recs"); file=${file%:*}; file=${file%:*}
  tail -c +$((start + 1)) "$file" | head -c $((end - start))
}
bad=""
while IFS='|' read -r attr want; do
  got=$(covered "$attr")
  [ "$got" = "$want" ] || bad="$bad | $attr: $got"
done <<'EOF'
site.select|self.revCount
site.default|self.revCount or 0
site.inherited|revCount
site.info|self.sourceInfo.revCount
site.bound|s.revCount
site.argument|self.revCount
site.builtin|builtins.getAttr "revCount" self
site.input|t.revCount
forced.json|no site
forced.values|no site
forced.computed|no site
forced.mapped|no site
forced.scope|no site
silent.allowed|exit 0, 0 findings
silent.other|exit 0, 0 findings
silent.whole|exit 0, 0 findings
EOF
[ -z "$bad" ]
check "$N: rev-count sites" $? "${bad# | }"
fcheck "$N: revCount: each spelling gives Nix's value" "$c#all"
# the count of a locked input comes from the lock, silent without a level
lib_repo
cin=$S/count-in
wr "$cin/flake.nix" "{ inputs.lib.url = \"git+file://$lib\"; outputs = { self, lib }: { n = toString lib.revCount; }; }
"
nlock "$cin" >/dev/null 2>&1
fcheck "$N: revCount: locked input" "$cin#n"
quiet=$(fenv "$bin" eval --raw --no-tracing-cache "$cin#n" 2>&1 >/dev/null)
wr "$cin/iets.toml" $'[lint.inputs.lib]\nrev-count = "warn"\n'
loud=$(fenv "$bin" eval --raw --no-tracing-cache "$cin#n" 2>&1 >/dev/null)
! has "$quiet" rev-count && has "$loud" "warning: [rev-count] 'inputs.lib.revCount' is deprecated" &&
  has "$loud" "
  at $cin/flake.nix:1:"
check "$N: rev-count, input" $? "$quiet | $loud"
echo >> "$c/flake.nix"
fcheck "$N: revCount: dirty tree" "$c#meta"
store_stop

# iets_fetches_a_tarball_input: Nix locks it in a store of its own, and iets
# downloads, unpacks, hashes and keeps the tree in its input store
store_start
N="$F/iets_fetches_a_tarball_input"
src=$S/tb2src
wr "$src/a" "hello $S
"
wr "$src/run" $'#!/bin/sh\n'; chmod 755 "$src/run"
wr "$src/sub/b" $'x\n'
ln -s a "$src/link"
tgz "$S" "$S/tb2.tar.gz" tb2src
tbf=$S/tbflake
wr "$tbf/flake.nix" "{
  inputs.tb.url = \"file://$S/tb2.tar.gz\";
  inputs.tb.flake = false;
  outputs = { self, tb }: { v = toString (builtins.attrNames (builtins.readDir tb)) + \" \" + builtins.readFile (tb + \"/a\"); };
}
"
lock_apart "$tbf" tb tbstore
tb_path=$inpath
fetch_only "$N: tarball: into iets's input store" "$tbf#v" "$exp"
# nothing was registered: the tree lives in the input store
entry=$S/cache/inputs/${tb_path##*/}
packs=$(ls "$S/cache/inputs/packs/"*.pack 2>/dev/null | wc -l)
[ -n "$tb_path" ] && [ ! -e "$tb_path" ] && [ -f "$entry" ] && [ "$packs" -gt 0 ]
check "$N: input store entry" $? "input store entry $entry, $packs packs"
# build --no-build sends the input's NAR out of the input store. The lock is
# written by hand, so Nix never fetches this input.
wr "$S/tb3src/a" "hello3 $S
"
wr "$S/tb3src/sub/b" $'y\n'
tgz "$S" "$S/tb3.tar.gz" tb3src
tb3=file://$S/tb3.tar.gz
# dereferenceSingletonDirectory strips the one top-level entry
h3=$(nar_hash "$S/tb3src")
upf=$S/upflake
usestb=$(cat <<'EOF'
{
  inputs.tb.url = "@URL@";
  inputs.tb.flake = false;
  outputs = { self, tb }: {
    packages.x86_64-linux.default = derivation {
      name = "usestb";
      system = "x86_64-linux";
      builder = "/bin/sh";
      args = [ "-c" "cp ${tb}/a $out" ];
    };
  };
}
EOF
)
wr "$upf/flake.nix" "${usestb//@URL@/$tb3}
"
wr "$upf/flake.lock" "$(tarball_lock tb "$tb3" "$h3")"
if [ $has_build = 1 ]; then
  run fenv "$bin" build --no-build --timings --iets-option builder daemon "$upf#packages.x86_64-linux.default"
  ub_rc=$rc ub_err=$err
  tb3_path=$(fenv "$bin" eval --raw --no-tracing-cache -E "(builtins.fetchTree { type = \"tarball\"; url = \"$tb3\"; narHash = \"$h3\"; }).outPath" 2>/dev/null)
  nixc path-info "$tb3_path" >/dev/null 2>&1 && valid=true || valid=false
  resolve=$(grep -m1 '^resolve:' <<<"$ub_err"); add=$(grep -m1 '^add:' <<<"$ub_err")
  bytes=$(sed -n 's/^[^,]*, \([0-9]*\) bytes.*/\1/p' <<<"$add"); bytes=${bytes:-0}
  [ $ub_rc = 0 ] && has "$ub_err" "fetching it" && [[ $resolve == "resolve: 1 sources"* ]] &&
    ! has "$resolve" "$S/store" && [ "$bytes" -gt 200 ] && [ $valid = true ]
  check "$N: build --no-build" $? "$resolve | $add | $tb3_path valid=$valid"
else skip "$N: build --no-build" "$no_build"; fi
# a filtered builtins.path of an input member uploads the NAR that
# evaluation hashed, which the daemon checks
wr "$S/tb4src/sub/b" $'b\n'
wr "$S/tb4src/sub/c" $'c\n'
tgz "$S" "$S/tb4.tar.gz" tb4src
tb4=file://$S/tb4.tar.gz
h4=$(nar_hash "$S/tb4src")
upg=$S/upflake2
usestbsub=$(cat <<'EOF'
{
  inputs.tb.url = "@URL@";
  inputs.tb.flake = false;
  outputs = { self, tb }: {
    packages.x86_64-linux.default = derivation {
      name = "usestbsub";
      system = "x86_64-linux";
      builder = "/bin/sh";
      args = [ "-c" "cat ${builtins.path { path = "${tb}/sub"; name = "tbsub"; filter = p: t: baseNameOf p != "c"; }}/b > $out" ];
    };
  };
}
EOF
)
wr "$upg/flake.nix" "${usestbsub//@URL@/$tb4}
"
wr "$upg/flake.lock" "$(tarball_lock tb "$tb4" "$h4")"
if [ $has_build = 1 ]; then
  run fenv "$bin" build --no-build --iets-option builder daemon "$upg#packages.x86_64-linux.default"
  [ $rc = 0 ] && has "$err" "fetching it"
  check "$N: filtered upload" $? "$(last "$err" 1)"
else skip "$N: filtered upload" "$no_build"; fi
# nix flake prefetch-inputs: both inputs land in the input store, and an
# evaluation then downloads nothing
wr "$S/tb5src/a" "hello5 $S
"
tgz "$S" "$S/tb5.tar.gz" tb5src
wr "$S/tb6src/a" "hello6 $S
"
tgz "$S" "$S/tb6.tar.gz" tb6src
tb5=file://$S/tb5.tar.gz; tb6=file://$S/tb6.tar.gz
h5=$(nar_hash "$S/tb5src"); h6=$(nar_hash "$S/tb6src")
pf=$S/prefetchflake
wr "$pf/flake.nix" "{ inputs.a = { url = \"$tb5\"; flake = false; }; inputs.b = { url = \"$tb6\"; flake = false; }; outputs = { self, a, b }: { v = builtins.readFile (a + \"/a\") + builtins.readFile (b + \"/a\"); }; }"
wr "$pf/flake.lock" "$(tarball_lock a "$tb5" "$h5" b "$tb6" "$h6")"
vars=(IETS_NIX_BIN_DIR="$nobin" PATH="$nobin" NIX_DAEMON_SOCKET_PATH=/nonexistent/iets-no-daemon IETS_CACHE_DIR="$S/prefetchcache")
run fenv "${vars[@]}" "$nixlink" flake prefetch-inputs "$pf"; p_rc=$rc p_err=$err; cp "$T/out" "$T/p.out"
run fenv "${vars[@]}" IETS_OFFLINE=1 "$bin" eval --raw --no-tracing-cache "$pf#v"
fetched=$(grep -c 'fetching it' <<<"$p_err")
[ $p_rc = 0 ] && [ ! -s "$T/p.out" ] && [ "$fetched" = 2 ] && [ $rc = 0 ] &&
  printf 'hello5 %s\nhello6 %s\n' "$S" "$S" | cmp -s - "$T/out" && ! has "$err" "fetching it"
check "$N: prefetch-inputs" $? "$(last "$p_err" 2) / $(last "$err" 2)"
# the lock's narHash is the contract: a changed tarball is refused, and
# nothing is registered. The input store entry goes first, or the fetch
# never happens.
rm -f "$entry"
wr "$src/a" $'changed\n'
tgz "$S" "$S/tb2.tar.gz" tb2src
run fenv IETS_NIX_BIN_DIR="$nobin" PATH="$nobin" "$bin" eval --raw --no-tracing-cache "$tbf#v"
[ $rc != 0 ] && [ ! -s "$T/out" ] && has "$err" "NAR hash mismatch" && [ -n "$tb_path" ] && [ ! -e "$tb_path" ]
check "$N: tarball mismatch" $? "$(last "$err" 2)"
store_stop

# a_second_process_waits_for_the_download: a sibling holds the tree's fetch
# lock and stores the entry before it lets go, so iets waits and reads it
store_start
N="$F/a_second_process_waits_for_the_download"
wr "$S/tb5src/a" "hello5 $S
"
tgz "$S" "$S/tb5.tar.gz" tb5src
url=file://$S/tb5.tar.gz
hash=$(nar_hash "$S/tb5src")
wf=$S/waitflake
wr "$wf/flake.nix" "{ inputs.tb = { url = \"$url\"; flake = false; }; outputs = { self, tb }: { v = builtins.readFile (tb + \"/a\"); }; }"
wr "$wf/flake.lock" "$(tarball_lock tb "$url" "$hash")"
nod=(IETS_NIX_BIN_DIR="$nobin" NIX_DAEMON_SOCKET_PATH=/nonexistent/iets-no-daemon)
wsrc=$S/waitsrc
run fenv "${nod[@]}" IETS_CACHE_DIR="$wsrc" "$bin" eval --raw --no-tracing-cache "$wf#v"; first_rc=$rc
wentry=
for p in "$wsrc"/inputs/*; do b=${p##*/}; [ -f "$p" ] && [ "${b:32:1}" = - ] && { wentry=$p; break; }; done
wc=$S/waitcache
mkdir -p "$wc/inputs"
cp "$wsrc/inputs/version" "$wc/inputs/version" 2>/dev/null
base=${wentry##*/}
lockf="$wc/inputs/.$base.fetching.tmp"
# a handshake, not a sleep: under load, iets could start after the sibling
# stored the entry and never wait
script="
flock '$lockf' sh -c 'touch $wc/held; for _ in \$(seq 600); do grep -qs \"waiting for another\" $wc/w.err && break; sleep 0.05; done; cp -r $wsrc/inputs/packs $wc/inputs/; cp $wentry $wc/inputs/' &
until [ -e $wc/held ]; do sleep 0.05; done
'$bin' eval --raw --no-tracing-cache '$wf#v' 2> $wc/w.err; s=\$?
cat $wc/w.err >&2; wait; exit \$s
"
run fenv "${nod[@]}" IETS_CACHE_DIR="$wc" IETS_OFFLINE=1 bash -c "$script"
[ $first_rc = 0 ] && [ -n "$wentry" ] && [ $rc = 0 ] && printf 'hello5 %s\n' "$S" | cmp -s - "$T/out" &&
  has "$err" "waiting for another process to fetch input 'tb'"
check "$N: fetch lock" $? "$out $(last "$err" 2)"
store_stop

# online_inputs: github.com and cache.nixos.org
N="$F/online_inputs"
if [ "${IETS_TEST_ONLINE:-}" != 1 ]; then
  skip "$N" "IETS_TEST_ONLINE unset"
else
  store_start
  ghf=$S/ghflake
  wr "$ghf/flake.nix" '{
  inputs.tiny.url = "github:numtide/flake-utils/471aed544aef9c610ea465cddf4a39c358ac5aa8";
  inputs.tiny.flake = false;
  outputs = { self, tiny }: { v = toString (builtins.attrNames (builtins.readDir tiny)); };
}
'
  lock_apart "$ghf" tiny ghstore
  [ ! -e "$inpath" ]
  check "$N: github: not in the store already" $? "$inpath"
  fetch_only "$N: github: fetched over https by iets" "$ghf#v" "$exp"
  # no nix, no daemon, a fresh cache: a fetch, then an offline hit
  vars=(IETS_NIX_BIN_DIR="$nobin" PATH="$nobin" NIX_DAEMON_SOCKET_PATH=/nonexistent/iets-no-daemon
    XDG_CACHE_HOME="$S/alone" IETS_CACHE_DIR="$S/alone/iets")
  run fenv "${vars[@]}" "$bin" eval --raw --no-tracing-cache "$ghf#v"; one=$out one_err=$err
  run fenv "${vars[@]}" IETS_OFFLINE=1 "$bin" eval --raw --no-tracing-cache "$ghf#v"
  entries=$(find "$S/alone/iets/inputs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
  [ -n "$exp" ] && [ "$one" = "$exp" ] && [ "$out" = "$exp" ] && has "$one_err" "fetching it" &&
    ! has "$err" "fetching it" && [ "$entries" -gt 0 ]
  check "$N: standalone" $? "$(last "$one_err" 3) / $(last "$err" 3)"
  store_stop
fi

# a_git_input_goes_through_nix: a missing git input goes to Nix, and
# without Nix it is an error that names the input
store_start
N="$F/a_git_input_goes_through_nix"
lib_repo
gitf=$S/gitflake
wr "$gitf/flake.nix" "{
  inputs.lib.url = \"git+file://$lib\";
  outputs = { self, lib }: { v = lib.greeting; };
}
"
lock_apart "$gitf" lib gitstore
run fenv IETS_NIX_BIN_DIR="$nobin" PATH="$nobin" "$bin" eval --raw --no-tracing-cache "$gitf#v"
[ $rc != 0 ] && has "$err" "nix is not on PATH" && has "$err" "input 'lib'"
check "$N: git input, no nix" $? "$(last "$err" 2)"
run fenv "$bin" eval --raw --no-tracing-cache "$gitf#v"
[ -n "$exp" ] && [ "$out" = "$exp" ] && [ -n "$inpath" ] && [ -e "$inpath" ]
check "$N: git input" $? "$out vs $exp $(last "$err" 2)"
# a tree that is not the one the lock names: the hint names the causes
gm=$S/gitmismatch
mkdir -p "$gm"; cp "$gitf/flake.nix" "$gm/flake.nix"
jq -c '.nodes.lib.locked.narHash = "sha256-aWV0cy1naXQtbWlzbWF0Y2gtbmV2ZXItc3RvcmVkISE="' "$gitf/flake.lock" > "$gm/flake.lock"
run fenv "$bin" eval --raw --no-tracing-cache --log-format internal-json "$gm#v"
rec=$(records "$err" | jq -c 'select(.code == "hash-mismatch")' | head -1)
[ $rc = 1 ] && has "$(jq -r '.hint // ""' <<<"${rec:-null}")" export-subst
check "$N: git mismatch" $? "$rc ${rec:-$(last "$err" 3)}"
store_stop

# without_a_lock
store_start
N="$F/without_a_lock"
# without inputs, Nix locks to an empty lock in memory and writes no file
nl=$S/nolock
wr "$nl/flake.nix" '{
  outputs = { self }: {
    v = builtins.toJSON { inherit (self) narHash lastModified lastModifiedDate outPath; };
    d = (derivation { name = "nolock"; system = "x86_64-linux"; builder = "/bin/sh"; args = [ "-c" "echo ${self} > $out" ]; }).drvPath;
  };
}
'
fcheck "$N: no lock: sourceInfo" "path:$nl#v"
fcheck "$N: no lock: drvPath" "path:$nl#d"
[ ! -e "$nl/flake.lock" ]
check "$N: no flake.lock appears" $? "a flake.lock appeared"
d="path:$nl#d"
fenv "$bin" eval --raw "$d" >/dev/null 2>&1
if [ $has_trace = 1 ]; then
  st=$(cache_lines "$d"); has "$st" "cache: hit"
  check "$N: no lock, second run" $? "$st"
else
  cache_lines "$d" >/dev/null
  skip "$N: no lock, second run" "$no_trace"
fi
wr "$nl/flake.lock" $'{\n'
run fenv "$bin" eval --raw "$d"
[ $rc != 0 ] && has "$err" "flake.lock missing or incomplete"
check "$N: a lock that appears" $? "$(last "$err" 2)"
# a declared input needs a lock entry, which nix flake lock writes
sub_flake
dl=$S/declared
wr "$dl/flake.nix" "{
  inputs.sub.url = \"path:$S/sub\";
  outputs = { self, sub }: { v = sub.value; };
}
"
run fenv "$bin" eval --raw --no-tracing-cache "path:$dl#v"
[ $rc != 0 ] && has "$err" "flake.lock missing or incomplete, run nix flake lock (input 'sub' has no lock entry)"
check "$N: declared" $? "$(last "$err" 2)"
run nlock "$dl"
check "$N: nix flake lock" $rc "$err"
fcheck "$N: no lock: evaluates after nix flake lock" "path:$dl#v"
# a formal of outputs that inputs does not name is a registry input
il=$S/implicit
wr "$il/flake.nix" $'{ outputs = { self, nixpkgs }: { v = "x"; }; }\n'
run fenv "$bin" eval --raw --no-tracing-cache "path:$il#v"
[ $rc != 0 ] && has "$err" "(input 'nixpkgs', an argument of 'outputs' that Nix looks up in the flake registry, has no lock entry)"
check "$N: implicit" $? "$(last "$err" 2)"
store_stop

# an_unfetchable_input: a locked remote input that no substituter has and
# no forge serves
store_start
N="$F/an_unfetchable_input"
ghost=$S/ghost
wr "$ghost/flake.nix" $'{ inputs.ghost.url = "github:NixOS/ghost"; outputs = { self, ghost }: { v = ghost.outPath; }; }\n'
ghost_lock='{"nodes":{"ghost":{"locked":{"type":"github","owner":"NixOS","repo":"ghost","rev":"0000000000000000000000000000000000000000","narHash":"sha256-Z2hvc3QtaW5wdXQtbmV2ZXItaW4tdGhlLXN0b3JlISE="},"original":{"type":"github","owner":"NixOS","repo":"ghost"}},"root":{"inputs":{"ghost":"ghost"}}},"root":"root","version":7}'
wr "$ghost/flake.lock" "$ghost_lock"
run fenv IETS_NIX_BIN_DIR="$nobin" PATH="$nobin" "$bin" eval --raw --no-tracing-cache "$ghost#v"
named=$(grep -c "input 'ghost'" <<<"$err")
[ $rc != 0 ] && [ ! -s "$T/out" ] && [ "$named" = 2 ] && has "$err" "cannot fetch input 'ghost'"
check "$N: unfetchable" $? "$(last "$err" 3)"
# a lock entry without a narHash: the hint names the input and the command
unl=$S/unlocked
mkdir -p "$unl"; cp "$ghost/flake.nix" "$unl/flake.nix"
jq -c 'del(.nodes.ghost.locked.narHash)' <<<"$ghost_lock" > "$unl/flake.lock"
run fenv "$bin" eval --raw --no-tracing-cache --log-format internal-json "$unl#v"
rec=$(records "$err" | jq -c 'select(.level == 0)' | head -1)
[ $rc = 3 ] && has "$(jq -r '.hint // ""' <<<"${rec:-null}")" "run 'nix flake update ghost'"
check "$N: unlocked entry" $? "$rc ${rec:-$(last "$err" 3)}"
run fenv IETS_NIX_BIN_DIR="$nobin" PATH="$nobin" "$nixlink" flake prefetch-inputs "$ghost"
[ $rc = 1 ] && has "$err" "cannot fetch input 'ghost'"
check "$N: prefetch-inputs ghost" $? "$rc $(last "$err" 2)"
store_stop

# symlinks_in_a_working_tree: iets reads the root tree from the working
# tree, so a link must resolve where the store copy puts it
store_start
N="$F/symlinks_in_a_working_tree"
wr "$S/outside.txt" $'outside\n'
sym=$S/sym
wr "$sym/flake.nix" '{
  outputs = { self }: {
    esc = builtins.readFile (self + "/esc");
    abs = builtins.readFile (self + "/abs");
    unt = builtins.readFile (self + "/unt");
    ok = builtins.readFile (self + "/okdir/t.txt");
    okdir = builtins.toJSON (builtins.readDir (self + "/okdir"));
    okex = builtins.toJSON (builtins.pathExists (self + "/okdir"));
    nar = self.narHash;
  };
}
'
wr "$sym/flake.lock" "$LOCK"
wr "$sym/d/t.txt" $'tracked\n'
wr "$sym/untracked.txt" $'untracked\n'
ln -s ../outside.txt "$sym/esc"
ln -s /nonexistent/iets-symlink-test "$sym/abs"
ln -s untracked.txt "$sym/unt"
ln -s d "$sym/okdir"
g "$sym" init -q
g "$sym" add flake.nix flake.lock d/t.txt esc abs unt okdir
g "$sym" commit -q -m sym
check_error "$N: sym: a link out of the tree is refused" "$sym#esc"
check_error "$N: sym: an absolute link is refused" "$sym#abs"
check_error "$N: sym: a link to an untracked file is Nix's git error" "$sym#unt"
fcheck "$N: sym: readFile through a tracked link" "$sym#ok"
fcheck "$N: sym: readDir of a tracked link" "$sym#okdir"
fcheck "$N: sym: pathExists of a tracked link" "$sym#okex"
# a flake directory that is a link is the working tree it points to
ln -s sym "$S/sym-link"
fcheck "$N: sym: a flake directory that is a link" "$S/sym-link#nar"
store_stop

# a_sparse_checkout_is_dirty: libgit2's status calls an index entry that is
# not on disk deleted, so a sparse checkout is a dirty tree
store_start
N="$F/a_sparse_checkout_is_dirty"
sparse=$S/sparse
wr "$sparse/flake.nix" $'{ outputs = { self }: { v = builtins.toJSON [ (self.rev or "none") (self.dirtyRev or "none") self.narHash (self.revCount or (-1)) ]; }; }\n'
wr "$sparse/flake.lock" "$LOCK"
wr "$sparse/d/f.txt" $'x\n'
wr "$sparse/top.txt" $'y\n'
g "$sparse" init -q; g "$sparse" add -A; g "$sparse" commit -q -m init
fcheck "$N: sparse: the whole tree is clean" "$sparse#v"
g "$sparse" sparse-checkout set --no-cone '/*' '!/d/'
fcheck "$N: sparse: an entry not on disk makes it dirty" "$sparse#v"
store_stop

# a_git_working_tree_caches
store_start
N="$F/a_git_working_tree_caches"
# every traced git query must be in trace::Query, or the run is uncacheable
cc=$S/cacheable
wr "$cc/flake.nix" $'{ outputs = { self }: { v = "c"; }; }\n'
wr "$cc/flake.lock" "$LOCK"
g "$cc" init -q; g "$cc" add -A
if [ $has_trace = 1 ]; then
  run fenv "$bin" eval --timings --raw "$cc#v"; cold=$err
  run fenv "$bin" eval --timings --raw "$cc#v"; warm=$err
  has "$cold" "cache: wrote" && has "$warm" "cache: hit"
  check "$N: cold then warm" $? "cold $(last "$cold" 2) warm $(last "$warm" 2)"
else skip "$N: cold then warm" "$no_trace"; fi
# the ancestor probes are observations: a cached result must not stay a
# path flake after git init above it
above=$S/above
wr "$above/fl/flake.nix" $'{ outputs = { self }: { v = builtins.toJSON [ (self ? rev) (builtins.pathExists (self + "/b")) ]; }; }\n'
wr "$above/fl/flake.lock" "$LOCK"
wr "$above/fl/b" $'b\n'
run fenv "$bin" eval --raw "$above/fl#v"; before_rc=$rc before=$out
g "$above" init -q
run fenv "$bin" eval --raw "$above/fl#v"; after_rc=$rc after_err=$err
nix_eval "$above/fl#v"
[ $before_rc = 0 ] && [ "$before" = "[false,true]" ] && [ $after_rc = $rc ] && [ $after_rc = 1 ] &&
  has "$after_err" "is not tracked by Git"
check "$N: above" $? "$before then $after_rc $(last "$after_err" 2) (nix $rc)"
store_stop

echo
echo "$passes passed, $skips skipped, $fails failed"
[ $fails = 0 ] || exit 1
