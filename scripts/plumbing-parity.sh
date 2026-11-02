#!/usr/bin/env bash
# `iets plumbing` against Rust: the cases of ../iets/tests/e2e_plumbing.rs
# that need no flake and no fetch, plus the usage errors. Stdout, stderr and
# the exit code must match. Cases that evaluate or plan run both binaries on
# the same files; cases that build give each binary derivations of its own
# (a nonce apiece), so both really build, and their store hashes, nonces
# and timings are normalised away. Builds only tiny /bin/sh derivations
# through the local nix-daemon.
# usage: scripts/plumbing-parity.sh [ZIG_BIN] [RUST_BIN]
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
zig=${1:-$here/zig-out/bin/iets}
rust=${2:-$here/../iets/target/release/iets}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
nonce="plumb$(date +%s%N)"
bad=0
pass=0

# drv NAME BUILD-SCRIPT: one derivation as Nix source
drv() {
  printf 'derivation {\n  name = "%s";\n  system = "x86_64-linux";\n  builder = "/bin/sh";\n  args = [ "-c" "%s" ];\n}\n' "$1" "$2"
}

# file N.nix for each side: N.r.nix and N.z.nix with their own nonce
pair() {
  local name=$1
  shift
  for side in r z; do "$@" "$side$nonce" > "$name.$side.nix"; done
}
hello() { drv plumb-hello "echo $1 > \$out"; }
bad_() { drv plumb-bad "echo boom $1 >\&2; exit 7"; }
chain() {
  cat <<EOF
let
  dep = derivation {
    name = "plumb-hello";
    system = "x86_64-linux";
    builder = "/bin/sh";
    args = [ "-c" "echo $1 > \$out" ];
  };
in derivation {
  name = "plumb-top";
  system = "x86_64-linux";
  builder = "/bin/sh";
  args = [ "-c" "echo \${dep} > \$out" ];
}
EOF
}

# the heartbeat and the download retries show only when the substituters
# are slow to answer
norm() {
  grep -Ev '^(⏵ querying|warning: unable to download)' | sed -E "s#/[a-z0-9]{32}-#/HASH-#g; s/[rz]$nonce/NONCE/g; s#(/gc|/ft|dump)[rz]\b#\1#g; s/\b[0-9]+(\.[0-9]+)?(ms|s)\b/T/g"
}

report() {
  local what=$1
  if cmp -s r.out z.out && cmp -s r.err z.err; then
    pass=$((pass + 1))
  else
    echo "DIFF: $what"
    diff r.out z.out | head -8
    diff r.err z.err | head -8
    bad=1
  fi
}

# same ARGS...: both binaries, the same arguments and stdin
same() {
  local input
  input=$(cat)
  printf '%s' "$input" | "$rust" plumbing "$@" > r.out 2> r.raw
  echo "exit $?" >> r.out
  printf '%s' "$input" | "$zig" plumbing "$@" > z.out 2> z.raw
  echo "exit $?" >> z.out
  grep -Ev '^(⏵ querying|warning: unable to download)' r.raw > r.err
  grep -Ev '^(⏵ querying|warning: unable to download)' z.raw > z.err
  report "plumbing $*"
}

# arg SIDE A: `@` in A replaced by the side (r or z); `=FILE` is FILE's
# first line, a drv path that differs per side
arg() {
  local a=${2//@/$1}
  if [[ $a == =* ]]; then head -1 "${a#=}"; else printf '%s' "$a"; fi
}

# own ARGS...: both binaries, each on its own derivations (see `arg`)
own() {
  local side bin args a
  for side in r z; do
    bin=$rust
    [ $side = z ] && bin=$zig
    args=()
    for a in "$@"; do args+=("$(arg $side "$a")"); done
    "$bin" plumbing "${args[@]}" > "$side.raw" 2> "$side.rawerr" < /dev/null
    echo "exit $?" >> "$side.raw"
    norm < "$side.raw" > "$side.out"
    norm < "$side.rawerr" > "$side.err"
  done
  report "plumbing $*"
}

# piped LEFT... -- RIGHT...: `iets plumbing LEFT | iets plumbing RIGHT`
piped() {
  local side bin left=() right=() a
  while [ "$1" != -- ]; do left+=("$1"); shift; done
  shift
  right=("$@")
  for side in r z; do
    bin=$rust
    [ $side = z ] && bin=$zig
    local l=() r=()
    for a in "${left[@]}"; do l+=("$(arg $side "$a")"); done
    for a in "${right[@]}"; do r+=("$(arg $side "$a")"); done
    "$bin" plumbing "${l[@]}" 2> "$side.lerr" < /dev/null | "$bin" plumbing "${r[@]}" > "$side.raw" 2> "$side.rawerr"
    echo "exit ${PIPESTATUS[0]} ${PIPESTATUS[1]}" >> "$side.raw"
    norm < "$side.raw" > "$side.out"
    cat "$side.lerr" "$side.rawerr" | norm > "$side.err"
  done
  report "plumbing ${left[*]} | plumbing ${right[*]}"
}

inst() { nix-instantiate "$1" 2> /dev/null; }

# usage errors
same < /dev/null
same foo < /dev/null
same resolv < /dev/null
same --help < /dev/null
same plan --help < /dev/null
same plan < /dev/null
same plan --roots x < /dev/null
same plan --bogus < /dev/null
same plan nope < /dev/null
same plan /nix/store/abc < /dev/null
same plan --drvs < /dev/null
same missing --check-cache-statu < /dev/null
same build --source x < /dev/null
same build --out < /dev/null
same resolve < /dev/null
same resolve -E < /dev/null
same resolve --walk x -E 1 < /dev/null
same resolve --want z < /dev/null
same resolve --prefixes q -E 1 < /dev/null
same resolve --log-format bogus -E 1 < /dev/null
same fetch < /dev/null
same fetch --unpack -E 1 < /dev/null
same fetch --hash-type foo x < /dev/null
for input in "" "{" "x" '{"roots":[1]}' '{"drvs":["nope"]}' '[1,]' '{"drvs":[]} x' \
  '{"roots":[{"drv":"/nix/store/abc"}]}' '{"a" 1}' '{"drvs":[]}' 'tru' '["a'; do
  same plan --roots - <<< "$input"
done

# resolve: the walks, the attribute paths, evaluation errors
drv plumb-hello "echo $nonce > \$out" > hello.nix
chain "$nonce" > chain.nix
cat > set.nix <<EOF
let
  mk = n: outs: derivation {
    name = n;
    system = "x86_64-linux";
    builder = "/bin/sh";
    args = [ "-c" "echo $nonce > \$out" ];
    outputs = outs;
  };
in {
  a = mk "plumb-wa" [ "out" ];
  sub = { recurseForDerivations = true; b = mk "plumb-wb" [ "out" ]; };
  hidden = { c = mk "plumb-wc" [ "out" ]; };
  multi = (mk "plumb-wm" [ "out" "dev" ]) // { meta.outputsToInstall = [ "dev" ]; };
}
EOF
cat > many.nix <<EOF
let
  dep = n: derivation {
    name = "plumb-dep-\${toString n}";
    system = "x86_64-linux";
    builder = "/bin/sh";
    args = [ "-c" "echo $nonce \${toString n} > \$out" ];
  };
  deps = builtins.genList dep 32;
in derivation {
  name = "plumb-root";
  system = "x86_64-linux";
  builder = "/bin/sh";
  args = [ "-c" "echo $nonce > \$out" ] ++ (map (d: "\${d}") deps);
}
EOF
hello_drv=$(inst hello.nix)
top_drv=$(inst chain.nix)
inst set.nix > /dev/null
same resolve hello.nix < /dev/null
same resolve chain.nix -A drvPath < /dev/null
same resolve --walk get-drvs set.nix < /dev/null
same resolve --walk get-drvs set.nix -A sub < /dev/null
same resolve --walk to-install set.nix -A multi < /dev/null
same resolve --walk to-install set.nix -A a < /dev/null
same resolve set.nix -A multi < /dev/null
same resolve --no-drvs set.nix < /dev/null
same resolve -E 'throw "x"' < /dev/null
same resolve -E 1 < /dev/null
same resolve --walk to-install -E 1 < /dev/null
same resolve --walk get-drvs -E 1 < /dev/null
same resolve set.nix -A nope < /dev/null

# --dump-drvs: every derivation, whichever fiber made it
for side in r z; do
  bin=$rust
  [ $side = z ] && bin=$zig
  "$bin" plumbing resolve --workers 4 --dump-drvs "dump$side" many.nix > "$side.raw" 2> "$side.err"
  norm < "$side.raw" > "$side.out"
  ls "dump$side" >> "$side.out"
done
report "resolve --dump-drvs"

# a helper claims one group's thunk and makes nine derivations under it;
# the demand path reaches them through the attribute, never through that
# thunk, so a dump held back with it would lose them
cat > deep.nix <<EOF
let
  dep = n: derivation {
    name = "plumb-deep-dep-\${toString n}";
    system = "x86_64-linux";
    builder = "/bin/sh";
    args = [ "-c" "echo $nonce \${toString n} > \$out" ];
  };
  group = g: {
    drv = derivation {
      name = "plumb-deep-group-\${toString g}";
      system = "x86_64-linux";
      builder = "/bin/sh";
      args = [ "-c" "echo $nonce > \$out" ] ++ map (n: "\${dep (g * 8 + n)}") (builtins.genList (x: x) 8);
    };
  };
  groups = map (g: (group g).drv) (builtins.genList (x: x) 16);
in derivation {
  name = "plumb-deep-root";
  system = "x86_64-linux";
  builder = "/bin/sh";
  args = [ "-c" "echo $nonce > \$out" ] ++ map (d: "\${d}") groups;
}
EOF
for i in 0 1 2; do
  rm -rf deep
  "$zig" plumbing resolve --workers 8 --dump-drvs deep deep.nix > /dev/null 2>&1
  n=$(ls deep | wc -l)
  if [ "$n" = 145 ]; then pass=$((pass + 1)); else echo "DIFF: deep dump run $i: $n of 145"; bad=1; fi
done

# plan and missing, on drvs in the store
same plan "$hello_drv" < /dev/null
same plan "$top_drv" < /dev/null
same plan "$top_drv!out,out" "$hello_drv!out" < /dev/null
same missing "$hello_drv" < /dev/null
same missing "$top_drv" < /dev/null
same missing --check-cache-status "$hello_drv" "$top_drv" < /dev/null
same plan --roots - <<< "{\"drvs\":[\"$top_drv\"]}"
same missing --roots - "$hello_drv!out" <<< "{\"roots\":[{\"drv\":\"$top_drv\",\"output\":\"out\"}]}"

# build: each side its own derivations
pair hello hello
pair bad bad_
pair fresh chain
for side in r z; do
  inst "hello.$side.nix" > "hello.$side.drv"
  inst "bad.$side.nix" > "bad.$side.drv"
done
mkdir gcr gcz
own build =hello.@.drv
own build =hello.@.drv
own build =bad.@.drv
own build --gc-root "$tmp/gc@" =hello.@.drv
own build --no-build =hello.@.drv
own build --fetch-to "$tmp/ft@" =hello.@.drv
own missing --check-cache-status =hello.@.drv =bad.@.drv
own build --out out =hello.@.drv

# fetch: a URL, and the hash a fixed-output derivation really produces
printf 'fetch me\n' > bytes.txt
tar czf bytes.tgz bytes.txt
same fetch "file://$tmp/bytes.txt" < /dev/null
same fetch --hash-type sha512 "file://$tmp/bytes.txt" < /dev/null
same fetch --hash-type md5 "file://$tmp/bytes.txt" --show-trace < /dev/null
same fetch --unpack "file://$tmp/bytes.tgz" < /dev/null
same fetch "file://$tmp/nope.txt" < /dev/null
same fetch -E '[]' < /dev/null
same fetch hello.nix < /dev/null
fod() {
  printf 'derivation {\n  name = "plumb-fod";\n  system = "x86_64-linux";\n  builder = "/bin/sh";\n  args = [ "-c" "echo %s > $out" ];\n  outputHashMode = "flat";\n  outputHash = "sha256-VhpZ3elSsC/qxbLhFHb8Xg0xhCdDPf7FcYWBODCRgbc=";\n}\n' "$1"
}
fod "$nonce" > fod.nix
same fetch fod.nix < /dev/null

# composition
piped plan =bad.@.drv -- build --roots -
piped resolve hello.@.nix -- missing --roots -
piped resolve fresh.@.nix -- plan --roots -
piped resolve --dump-drvs dump@ fresh.@.nix -- plan --roots -
piped resolve --dump-drvs dump@ fresh.@.nix -- build --roots -

echo "$pass cases pass"
[ $bad = 0 ] && echo PLUMBING PARITY
exit $bad
