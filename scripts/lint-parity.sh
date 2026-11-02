#!/usr/bin/env bash
# The lint fixtures of ../iets/tests/lint against the Rust oracle: each
# fixture at its default level, at warn and at error (src/lint/fixtures.rs),
# then the cases of src/lint/cases.rs and cli_cases.rs that run from the
# command line. stdout, stderr and the exit code must match byte for byte.
# usage: scripts/lint-parity.sh [BIN] [WORKERS]   (default zig-out/bin/iets, 1)
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
bin=$(realpath "${1:-$here/zig-out/bin/iets}")
workers=${2:-1}
oracle=${ORACLE:-$here/../iets/target/release/iets}
lint=$(cd "$here/../iets/tests/lint" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; rm -rf "$lint/git-in-source.d/.git"' EXIT
# git refuses to track a `.git` entry, so the fixture gets one at run time
mkdir -p "$lint/git-in-source.d/.git"
pass=0
fail=0
skip=0

# Known gaps, each for a reason outside the lint port.
skip_case() {
  case "$1" in
    # fetchers are stubs; getFlake and the tracing cache are not ported
    # tree-meta-in-drv*) return 0 ;;
  esac
  return 1
}

# The trace lines of builtin calls (`… while calling the 'importRaw'
# builtin`) are a known gap of the error output, not of the lints.
norm() { sed -i "/^       … while calling the '.*' builtin/d" "$1"; }

run() { # name, then the arguments
  local name=$1
  shift
  if skip_case "$name"; then
    skip=$((skip + 1))
    return
  fi
  (cd "$lint" && env -u IETS_LINT XDG_CONFIG_HOME="$tmp/xdg" "$oracle" "$@" >"$tmp/o.out" 2>"$tmp/o.err"; echo "rc=$?" >>"$tmp/o.out")
  if [ -n "${CACHE:-}" ]; then
    (cd "$lint" && env -u IETS_LINT IETS_IR_MIN=0 XDG_CONFIG_HOME="$tmp/xdg" "$bin" "$@" >/dev/null 2>&1)
  fi
  (cd "$lint" && env -u IETS_LINT IETS_IR_MIN=0 XDG_CONFIG_HOME="$tmp/xdg" "$bin" "$@" >"$tmp/z.out" 2>"$tmp/z.err"; echo "rc=$?" >>"$tmp/z.out")
  norm "$tmp/o.err"
  norm "$tmp/z.err"
  if cmp -s "$tmp/o.out" "$tmp/z.out" && cmp -s "$tmp/o.err" "$tmp/z.err"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL $name: $*"
    diff <(cat "$tmp/o.out" "$tmp/o.err") <(cat "$tmp/z.out" "$tmp/z.err") | head -20
  fi
}

# CACHE=1: through an IR cache, written by the first run and read by the
# second (Rust's tracing cache stays off).
if [ -n "${CACHE:-}" ]; then
  ev=(eval --no-tracing-cache --cache-dir "$tmp/cache" --workers "$workers")
else
  ev=(eval --no-cache --workers "$workers")
fi
for f in "$lint"/*.nix; do
  n=$(basename "$f" .nix)
  flags=()
  if [ -f "$lint/$n.flags" ]; then read -ra flags <"$lint/$n.flags"; fi
  for lv in default warn error; do
    extra=()
    [ "$lv" != default ] && extra=(--lint "$n=$lv")
    run "$n.$lv" "${ev[@]}" --strict "${flags[@]}" "${extra[@]}" "$f"
  done
done

# src/lint/cases.rs
run all-then-off "${ev[@]}" --lint all=warn --lint url-literal=off url-literal.nix
run off-then-all "${ev[@]}" --lint url-literal=off --lint all=warn url-literal.nix
run family "${ev[@]}" --lint family:legacy=warn url-literal.nix
run toml "${ev[@]}" cases/toml/main.nix
run toml-family "${ev[@]}" cases/family/main.nix
run toml-member "${ev[@]}" cases/family/member.nix
run untrusted "${ev[@]}" cases/untrusted/main.nix
run unknown "${ev[@]}" cases/unknown/main.nix
run dedup "${ev[@]}" --strict --lint eq-type-mismatch=warn cases/dedup.nix
run tryeval "${ev[@]}" --lint eq-type-mismatch=error cases/tryeval.nix
for s in "" "--lint-scope all" "--lint-root scope/lib"; do
  # shellcheck disable=SC2086
  run "scope $s" "${ev[@]}" --lint url-literal=warn $s scope/root/main.nix
done
run scope-all "${ev[@]}" --lint url-literal=warn scope/all/main.nix
run scope-roots "${ev[@]}" --lint url-literal=warn scope/roots/main.nix
run scope-drv "${ev[@]}" --lint drv-list=warn scope/root/drv.nix
run scope-fod "${ev[@]}" --lint fod=warn scope/root/fod.nix
run scope-own "${ev[@]}" --lint drv-list=warn scope/root/own.nix
for f in own-line trailing multiple family all blank-lines runtime; do
  run "allow/$f" "${ev[@]}" --strict --lint url-literal=warn --lint eq-type-mismatch=warn "allow/$f.nix"
done
run allow/next-line-only "${ev[@]}" --strict --lint url-literal=warn allow/next-line-only.nix
run allow/error-level "${ev[@]}" --lint url-literal=error allow/error-level.nix
run allow/directive "${ev[@]}" --lint url-literal=warn allow/directive.nix
for v in "url-literal=warn" "url-literal=off,family:legacy=warn" "nope=warn,url-literal=warn" "bad=x"; do
  (cd "$lint" && IETS_LINT="$v" XDG_CONFIG_HOME="$tmp/xdg" "$oracle" "${ev[@]}" url-literal.nix >"$tmp/o.out" 2>"$tmp/o.err"; echo "rc=$?" >>"$tmp/o.out")
  (cd "$lint" && IETS_LINT="$v" XDG_CONFIG_HOME="$tmp/xdg" "$bin" "${ev[@]}" url-literal.nix >"$tmp/z.out" 2>"$tmp/z.err"; echo "rc=$?" >>"$tmp/z.out")
  norm "$tmp/o.err"; norm "$tmp/z.err"
  if cmp -s "$tmp/o.out" "$tmp/z.out" && cmp -s "$tmp/o.err" "$tmp/z.err"; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL IETS_LINT=$v"; diff <(cat "$tmp/o.out" "$tmp/o.err") <(cat "$tmp/z.out" "$tmp/z.err") | head; fi
done
for f in url-literal.nix cases/toml/main.nix; do
  (cd "$lint" && XDG_CONFIG_HOME="$lint/user" "$oracle" "${ev[@]}" "$f" >"$tmp/o.out" 2>"$tmp/o.err"; echo "rc=$?" >>"$tmp/o.out")
  (cd "$lint" && XDG_CONFIG_HOME="$lint/user" "$bin" "${ev[@]}" "$f" >"$tmp/z.out" 2>"$tmp/z.err"; echo "rc=$?" >>"$tmp/z.out")
  norm "$tmp/o.err"; norm "$tmp/z.err"
  if cmp -s "$tmp/o.out" "$tmp/z.out" && cmp -s "$tmp/o.err" "$tmp/z.err"; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL user iets.toml $f"; diff <(cat "$tmp/o.out" "$tmp/o.err") <(cat "$tmp/z.out" "$tmp/z.err") | head; fi
done

# src/lint/cli_cases.rs
run lint-list lint list
run lint-list-flag lint list --lint url-literal=error
run lint-list-scope lint list --lint-scope all scope/root/main.nix
run lint-list-roots lint list scope/roots/main.nix
run lint-list-inputs lint list --lint family:purity=error cases/unknown/main.nix
run lint-missing lint
run lint-unknown lint foo
run lint-bad-flag lint list --bogus
run bad-lint "${ev[@]}" --lint nope=warn url-literal.nix
run bad-level "${ev[@]}" --lint url-literal=loud url-literal.nix
run bad-scope "${ev[@]}" --lint-scope x url-literal.nix
run nix-flag "${ev[@]}" --lint-url-literals warn url-literal.nix
run nix-flag-fatal "${ev[@]}" --lint-url-literals fatal url-literal.nix
run nix-flag-bad "${ev[@]}" --lint-url-literals loud url-literal.nix
run expr "${ev[@]}" --lint url-literal=warn -E 'http://x.y'
run trace "${ev[@]}" --lint url-literal=warn -E 'builtins.trace 1 (http://x.y)'

# src/lint/flake_cases.rs: a flake with a `path:` input, in a scratch copy
# of tests/lint/scope/flake whose lock names the input's NAR hash. The last
# case (a finding replayed on a tracing-cache hit) waits for trace/.
fl="$tmp/flake"
mkdir -p "$fl" && cp -r "$lint/scope/flake/root" "$lint/scope/flake/dep" "$fl/"
dep_hash=$("$oracle" eval --raw --impure --no-tracing-cache -E "(builtins.fetchTree { type = \"path\"; path = \"$fl/dep\"; }).narHash")
store_path=$(printf '%s\n' "$PATH" | tr ':' '\n' | sed -n 's|^\(/nix/store/[^/]*\).*|\1|p' | head -1)
for f in flake.nix flake.lock; do
  sed -i "s|@DEP@|$fl/dep|g; s|@HASH@|$dep_hash|g; s|@STORE@|$store_path|g" "$fl/root/$f"
done
fev=(eval --raw --no-tracing-cache --no-cache --workers "$workers")
copies=(--lint store-path-recopy=warn --lint path-copy=warn --lint dir-copy-flake=warn)
run flake-input-scope "${fev[@]}" --lint url-literal=warn "$fl/root#value"
run flake-input-scope-all "${fev[@]}" --lint url-literal=warn --lint-scope all "$fl/root#value"
run flake-copy-file "${fev[@]}" "${copies[@]}" "$fl/root#file"
run flake-copy-input-file "${fev[@]}" --lint-scope all "${copies[@]}" "$fl/root#inputFile"
run flake-dir-copy "${fev[@]}" "${copies[@]}" "$fl/root#dir"
run flake-dir-copy-error "${fev[@]}" --lint dir-copy-flake=error "$fl/root#dir"
[ -n "$store_path" ] && run flake-store-recopy "${fev[@]}" --impure "${copies[@]}" "$fl/root#store"
run flake-meta "${fev[@]}" "$fl/root#meta.drvPath"
run flake-meta-wrapped "${fev[@]}" "$fl/root#wrapped.drvPath"
run flake-meta-error "${fev[@]}" --lint tree-meta-in-drv=error "$fl/root#meta.drvPath"
run flake-meta-allowed "${fev[@]}" "$fl/root#allowed.drvPath"
run flake-meta-dep "${fev[@]}" "$fl/root#depMeta.drvPath"
run flake-meta-dep-all "${fev[@]}" --lint-scope all "$fl/root#depMeta.drvPath"
mkdir -p "$tmp/xdg/iets" && printf '[lint]\ntree-meta-in-drv = "error"\n' >"$tmp/xdg/iets/iets.toml"
run flake-meta-user-file "${fev[@]}" "$fl/root#meta.drvPath"
rm -rf "$tmp/xdg/iets"
for v in "family:purity=off"; do
  (cd "$lint" && IETS_LINT="$v" XDG_CONFIG_HOME="$tmp/xdg" "$oracle" "${fev[@]}" "$fl/root#meta.drvPath" >"$tmp/o.out" 2>"$tmp/o.err"; echo "rc=$?" >>"$tmp/o.out")
  (cd "$lint" && IETS_LINT="$v" XDG_CONFIG_HOME="$tmp/xdg" "$bin" "${fev[@]}" "$fl/root#meta.drvPath" >"$tmp/z.out" 2>"$tmp/z.err"; echo "rc=$?" >>"$tmp/z.out")
  if cmp -s "$tmp/o.out" "$tmp/z.out" && cmp -s "$tmp/o.err" "$tmp/z.err"; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL flake IETS_LINT=$v"; diff <(cat "$tmp/o.out" "$tmp/o.err") <(cat "$tmp/z.out" "$tmp/z.err") | head; fi
done
printf '[lint.inputs.dep]\nurl-literal = "warn"\n' >"$fl/root/iets.toml"
run flake-inputs-table "${fev[@]}" --lint url-literal=warn "$fl/root#value"
printf '[lint]\ntree-meta-in-drv = "off"\n[lint.inputs.dep]\ntree-meta-in-drv = "warn"\n' >"$fl/root/iets.toml"
run flake-meta-per-tree "${fev[@]}" "$fl/root#depMeta.drvPath"
run flake-meta-per-tree-root "${fev[@]}" "$fl/root#meta.drvPath"
rm -f "$fl/root/iets.toml"

# Deferral: `elem` fans its list out, and helpers force the elements past
# the match that the program never asks for. Their findings must not show,
# and the others come in order (docs/explanation/evaluation.md).
python3 -c '
els = [f"({i} == \"s{i}\")" for i in range(60)] + ["true"] + [f"({i} == \"t{i}\")" for i in range(60, 400)]
print("builtins.elem true [\n" + "\n".join(els) + "\n]")' >"$tmp/defer.nix"
for w in 1 4 8 16; do
  run "defer w=$w" eval --no-cache --workers "$w" --lint eq-type-mismatch=warn "$tmp/defer.nix"
done

echo "lint parity: $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]
