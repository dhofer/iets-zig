#!/usr/bin/env bash
# The command line against Rust: `--help` and `iets help TOPIC` for every
# command and page, the usage errors with their suggestions, `version`,
# tab completion and its six scripts, `iets eval`, `parse`, `lint list` and
# `search` on small fixtures. Stdout, stderr and the exit code must match
# (session ids and activity ids are normalised away). Also checks that the
# embedded pages and completion scripts are the Rust tree's, up to the
# divergences `ours` maps back.
# usage: scripts/cli-parity.sh [ZIG_BIN] [RUST_BIN]
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
zig=${1:-$here/zig-out/bin/iets}
rust=${2:-$here/../iets/target/release/iets}
zig=$(cd "$(dirname "$zig")" && pwd)/$(basename "$zig")
rust=$(cd "$(dirname "$rust")" && pwd)/$(basename "$rust")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
bad=0
pass=0

norm() { sed -E 's/"sid":"[^"]*"/"sid":X/g; s/"id":[0-9]+/"id":X/g; s/, [0-9]+\.[0-9]{3}s$/, Ts/'; }
# the deliberate divergences, mapped back to Rust's text: the cache root is
# `iets-zig`, so the two binaries never share (and wipe) each other's stores
ours() { sed -E 's#(XDG_CACHE_HOME|\.cache)/iets-zig#\1/iets#g'; }

# same ARGS...: both binaries, the same stdout, stderr and exit code
same() {
  "$rust" "$@" > r.out 2> r.err < /dev/null; local rr=$?
  "$zig" "$@" 2> z.err < /dev/null | ours > z.out; local zr=${PIPESTATUS[0]}
  norm < r.err > r.errn; ours < z.err | norm > z.errn
  if [ $rr = $zr ] && cmp -s r.out z.out && cmp -s r.errn z.errn; then
    pass=$((pass + 1))
  else
    bad=$((bad + 1))
    echo "FAIL iets $* (exit $rr vs $zr)"
    diff r.out z.out | head -5
    diff r.errn z.errn | head -5
  fi
}

# the copies this port embeds
for f in "$here"/src/cli/docs/*.md; do
  ours < "$f" | cmp -s - "$here/../iets/docs/reference/$(basename "$f")" || { bad=$((bad + 1)); echo "FAIL src/cli/docs/$(basename "$f") differs from ../iets/docs/reference"; }
done
for f in "$here"/src/cli/complete/iets.*; do
  cmp -s "$f" "$here/../iets/src/cli/complete/$(basename "$f")" || { bad=$((bad + 1)); echo "FAIL src/cli/complete/$(basename "$f") differs from ../iets"; }
done

commands="eval build search diff eval-jobs print-dev-env prefetch plumbing lint parse cache completion"
topics=$("$rust" help | sed -n 's/^[ *] \([a-z-]*\) .*/\1/p')

same
same --help
same -h
same help
same version
same --version
same --foo
same -h x
for c in $commands; do same "$c" --help; same help "$c"; done
for t in $topics bogus settigns reference/plumbing explanation/caching reference/caching; do same help "$t"; done
for w in bogus evl buidl serach verison nix-buidl eval-jbos; do same "$w"; done
same cache
same cache dunp
same cache dump
same cache dump a b
same cache-dump
same lint
same lint lst
same completion
same completion bsh
same completion fish extra
for sh in bash zsh fish nushell elvish powershell; do same completion "$sh"; done
for c in eval build search diff eval-jobs print-dev-env plumbing lint parse; do
  same "$c" --no-cach x
  same "$c" --workers
  same "$c" -I
done
same eval --workers 0 -E 1
same eval --lint bogus=warn -E 1
same eval --lint-scope x -E 1
same eval -E
same eval -E 1 f.nix
same eval
same parse
same parse x.nix --nope

# completion
echo '{ lib = { alpha = 1; beta = 2; }; pkgs = { hello = 1; }; "a.b" = 1; }' > x.nix
for words in "" "bu" "-" "eval --st" "eval --he" "build --no-" "help " "help build " \
  "cache " "completion " "completion f" "completion fish " "lint " "nix-build " "bogus " \
  "eval --file " "eval --arg n " "eval --arg n 1 --js" "eval --workers -" \
  "cache gc --cache-dir " "lint list --lint-scope " "plumbing resolve --prefixes " \
  "eval -f x.nix -A " "eval x.nix -A lib.b" "eval -A a" "eval -f nope.nix -A a"; do
  # the last word is the one under the cursor, empty after a trailing space
  read -ra w <<< "$words"
  case "$words" in *" " | "") w+=("") ;; esac
  same __complete "${w[@]}"
done
same __complete eval -E '{ a = 1; ab = 2; }' --attr a

# eval
echo '{ x ? 1, y }: { a = x; b.c = y; s = "str"; }' > f.nix
same eval -E '1 + 2'
same eval -E '{ x ? 1 }: x'
same eval -f f.nix --arg y 2 -A b
same eval f.nix --argstr y q -A b.c --raw
same eval f.nix --arg y 2 --json
same eval f.nix --arg y 2 --strict
same eval f.nix --arg y 2 -A a -A b.c
same eval f.nix --arg y '1 +' -A b
same eval -E '{a=1;}' --raw
same eval -E '[1 2]' --raw
same eval -E 'throw "x"'
same eval -E 'abort "x"' --log-format internal-json
same eval -E 'http://x.com' --lint url-literal=error
same eval --no-cache -E 'builtins.trace "root" { a = 1; b = 2; c = throw "boom"; }' -A b -A a
same eval --no-cache -E 'builtins.trace "root" { a = 1; b = 2; c = throw "boom"; }' -A a -A c -A b

# parse and lint list
echo '{ a = ; }' > bad.nix
echo '{ }' > ok.nix
same parse ok.nix
same parse --json ok.nix
same parse --log-format internal-json bad.nix nonexist.nix
same parse -q ok.nix bad.nix nonexist.nix
same lint list
same lint list --lint x
same lint list --lint bogus=warn
same lint list --lint url-literal=error --lint-scope all
same lint list --nope

# search
cat > pkgs.nix <<'EOF'
{ x ? 1 }:
let mk = name: desc: { type = "derivation"; inherit name; meta.description = desc; outPath = "/nix/store/x-${name}"; };
in {
  hello = mk "hello-2.12" "A program that\nproduces a greeting";
  goodbye = mk "goodbye-1.0" "Says goodbye";
  sub = { recurseForDerivations = true; inner = mk "inner-0.1" "inner package"; };
  hidden = { notrec = mk "nope-1" "x"; };
  bad = throw "boom";
}
EOF
for a in "-f pkgs.nix hello" "-f pkgs.nix ^" "pkgs.nix ^ --json" "pkgs.nix good --json --pretty" \
  "pkgs.nix ^ -e good" "pkgs.nix zzz" "pkgs.nix" "--foo pkgs.nix x" "pkgs.nix [" "--expr {} x" \
  "pkgs.nix ^ --arg x 2" "pkgs.nix sub" "--pure-eval -f pkgs.nix x" "pkgs.nix -e" \
  "pkgs.nix x --workers 0" "-I nixpkgs=./pkgs.nix hello" "-I nixpkgs=. hello"; do
  read -ra w <<< "$a"
  same search --no-cache "${w[@]}"
done
IETS_NO_FALLBACK=1 same nix search -f pkgs.nix hello
IETS_NO_FALLBACK=1 same nix search --foo x

# a flake: fragment completion and search
mkdir fl
pk=""
for sy in x86_64-linux aarch64-linux x86_64-darwin aarch64-darwin x86_64-windows aarch64-windows; do
  pk="$pk $sy = { hello = 1; help = 2; other = 3; \"a.b\" = 4; };"
done
echo "{ outputs = _: { packages = { $pk }; lib.answer = 42; devShells.x86_64-linux.dev = 1; }; }" > fl/flake.nix
cd fl
for w in ".#he" ".#packages." ".#.lib.an" ".#pack" ".#zzz" "/nonexistent#a" "#he"; do
  for c in eval print-dev-env search; do same __complete "$c" "$w"; done
done
cd ..
mkdir fs
cat > fs/flake.nix <<'NIX'
{ outputs = _: let mk = name: desc: { type = "derivation"; inherit name; meta.description = desc; outPath = "/nix/store/x-${name}"; }; in {
  packages.x86_64-linux = { hello = mk "hello-1.0" "Hi"; world = mk "world-2" "Earth"; };
  legacyPackages.x86_64-linux = { sub = { recurseForDerivations = true; deep = mk "deep-3" "down"; inner.x = mk "x-1" "no"; }; bad = throw "x"; };
}; }
NIX
echo '{"nodes":{"root":{}},"root":"root","version":7}' > fs/flake.lock
cd fs
for a in ". ^" ".#hello ^" ".#sub ^" "path:. ^ --json" ".#nope x" "/nonexistent ^" "github:a/b ^"; do
  read -ra w <<< "$a"
  same search --no-cache "${w[@]}"
done
cd ..

echo "cli parity: $pass passed, $bad failed"
[ $bad = 0 ]
