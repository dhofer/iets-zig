#!/usr/bin/env bash
# `iets diff` against Rust on the cases of ../iets/tests/diff.rs that need no
# evaluation by iets: the sides are .drv files nix-instantiate makes from
# small derivations, and for --closure their tiny outputs nix-build makes.
# Stdout, stderr (the session id dropped) and the exit code must match.
# usage: scripts/diff-parity.sh [ZIG_BIN] [RUST_BIN]
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
zig=${1:-$here/zig-out/bin/iets}
rust=${2:-$here/../iets/target/release/iets}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/data"
echo one > "$tmp/data/one.txt"
echo two > "$tmp/data/two.txt"
cat > "$tmp/demo.nix" <<'EOF'
let
  dep = msg: derivation {
    name = "diffdep";
    system = "x86_64-linux";
    builder = "/bin/sh";
    args = [ "-c" "echo ${msg} > $out" ];
  };
  top = { msg, greeting, src }: derivation {
    name = "diffdemo";
    system = "x86_64-linux";
    builder = "/bin/sh";
    args = [ "-c" "cat ${dep msg} ${src} > $out" ];
    GREETING = greeting;
  };
  mk = n: derivation {
    name = n;
    system = "x86_64-linux";
    builder = "/bin/sh";
    args = [ "-c" "echo hi > $out" ];
  };
  # outputs that are built, for --closure: each a line of text
  pkg = name: deps: derivation {
    inherit name;
    system = "x86_64-linux";
    builder = "/bin/sh";
    args = [ "-c" "echo ${builtins.concatStringsSep " " (map toString deps)} > $out" ];
  };
  same = pkg "diffsame-3" [ ];
in {
  a = top { msg = "one"; greeting = "hello"; src = ./data/one.txt; };
  b = top { msg = "two"; greeting = "goodbye"; src = ./data/two.txt; };
  c = top { msg = "one"; greeting = "hello"; src = ./data/one.txt; };
  one = mk "ux-one";
  two = mk "ux-two";
  multi = derivation {
    name = "diffmulti";
    system = "x86_64-linux";
    builder = "/bin/sh";
    outputs = [ "out" "dev" ];
    args = [ "-c" "echo \"tab\there\" > $out" ];
    __structuredAttrs = true;
    n = 1.5;
  };
  fod = derivation {
    name = "diffdep";
    system = "x86_64-linux";
    builder = "/bin/sh";
    args = [ "-c" "echo one > $out" ];
    outputHashMode = "flat";
    outputHash = "sha256-JLAVSZGkK8U8VGHswB4NsI4xjMv9KSOabvFS6l7f7Ac=";
  };
  appA = pkg "diffapp-1.0" [ (pkg "difflib-1.0" [ ]) same (pkg "diffgone-0.1" [ ]) ];
  appB = pkg "diffapp-1.1" [ (pkg "difflib-2.0" [ ]) same (pkg "diffextra" [ ]) ];
  missing = pkg "diffmissing-1.0" [ ];
}
EOF
drv() { nix-instantiate "$tmp/demo.nix" -A "$1" 2>/dev/null; }
A=$(drv a) B=$(drv b) C=$(drv c) ONE=$(drv one) TWO=$(drv two)
MULTI=$(drv multi) FOD=$(drv fod) APPA=$(drv appA) APPB=$(drv appB) MISSING=$(drv missing)
nix-build "$tmp/demo.nix" -A appA -A appB --no-out-link > /dev/null 2>&1 || {
  echo "nix-build of the --closure outputs failed"; exit 2; }
Z0=/nix/store/00000000000000000000000000000000-x.drv

cases=(
  "$A $B"
  "--json $A $B"
  "$A $C"
  "--json $A $C"
  "--depth 0 $A $B"
  "--depth 0 --json $A $B"
  "--all $B $A"
  "--depth 1 $A $B"
  "$ONE $TWO"
  "$A $MULTI"
  "--json $MULTI $A"
  "$FOD $(nix-instantiate "$tmp/demo.nix" -A b 2>/dev/null)"
  "$A $FOD"
  "--closure $APPA $APPB"
  "--closure --json $APPA $APPB"
  "--closure $APPA $APPA"
  "--closure $APPA $MISSING"
  "--closure --builder foo://x $APPA $APPB"
  "--closure --builder unix:///nonexistent/socket $APPA $APPB"
  "$Z0 $A"
  "$Z0 $Z0"
  "-A a"
  "$A"
  "$A $B $C"
  "-A a -A b --bogus"
  "--jsn $A $B"
  "--depth x $A $B"
  "--depth"
  "-E"
  "-A a -A b -E 1 x"
  "/nix/store/aaaa.drv $B"
  "$A ./not-a-store-path.drv"
  "--option pure-eval maybe $A $B"
  "--log-format bad $A $B"
  "--log-format internal-json --bogus"
  "--log-format internal-json $Z0 $A"
  "--help"
  "--depth 0 --help"
)

bad=0
n=0
for c in "${cases[@]}"; do
  n=$((n + 1))
  (cd "$tmp" && "$zig" diff $c > "$tmp/z.out" 2> "$tmp/z.err"); zrc=$?
  (cd "$tmp" && "$rust" diff $c > "$tmp/r.out" 2> "$tmp/r.err"); rrc=$?
  sed -i 's/"sid":"[^"]*"/"sid":""/' "$tmp/z.err" "$tmp/r.err"
  if [ $zrc != $rrc ] || ! cmp -s "$tmp/z.out" "$tmp/r.out" || ! cmp -s "$tmp/z.err" "$tmp/r.err"; then
    echo "DIFF: iets diff $c (exit $zrc, Rust $rrc)"; bad=1
    diff "$tmp/z.out" "$tmp/r.out" | head -5
    diff "$tmp/z.err" "$tmp/r.err" | head -5
  fi
done
echo "$n cases"
[ $bad = 0 ] && echo DIFF PARITY
exit $bad
