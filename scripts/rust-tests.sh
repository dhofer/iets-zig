#!/usr/bin/env bash
# Runs the Rust iets's own integration tests against a binary: a copy of
# ../iets/tests in a crate of its own, with `CARGO_BIN_EXE_iets` pointed at
# BIN (default: this port's ReleaseFast build). The Rust tree is not touched.
#
#   scripts/rust-tests.sh [BIN] [TEST...] [-- CARGO-TEST-ARGS]
#   scripts/rust-tests.sh zig-out/bin/iets e2e_build e2e_daemon -- --test-threads 4
#
# Each TEST is a file of ../iets/tests without `.rs`. Needs `nix develop` in
# ../iets for cargo (it is entered here) and its registry cache.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
rust=$(cd "$here/../iets" && pwd)
bin=${1:-$here/zig-out-rel/bin/iets}
shift || true
bin=$(cd "$(dirname "$bin")" && pwd)/$(basename "$bin")
tests=()
while [ $# -gt 0 ] && [ "$1" != "--" ]; do tests+=("$1"); shift; done
[ "${1:-}" = "--" ] && shift
[ ${#tests[@]} -gt 0 ] || tests=(e2e_build e2e_daemon e2e_grpc e2e_evaljobs e2e_plumbing diff ifd)

crate=${IETS_RUST_TESTS_DIR:-/tmp/iets-rust-tests}
mkdir -p "$crate/src"
rm -rf "$crate/tests"
cp -r "$rust/tests" "$crate/tests"
# only the requested test files stay top-level; their modules stay too
for f in "$crate"/tests/*.rs; do
  name=$(basename "$f" .rs)
  keep=0
  for t in "${tests[@]}"; do [ "$t" = "$name" ] && keep=1; done
  [ $keep = 1 ] || rm "$f"
done
grep -rl 'CARGO_BIN_EXE_iets' "$crate/tests" | xargs sed -i 's/env!("CARGO_BIN_EXE_iets")/env!("IETS_BIN")/g'
# the crate's constants a test reads, as literals: this crate links no iets
{ grep -rl 'iets::config::DEFAULT_SYSTEM' "$crate/tests" || true; } | xargs -r sed -i "s/iets::config::DEFAULT_SYSTEM/\"$(uname -m)-linux\"/g"
cp "$rust/Cargo.lock" "$crate/Cargo.lock"
echo 'fn main() {}' > "$crate/src/main.rs"
cat > "$crate/Cargo.toml" <<TOML
[package]
name = "iets-rust-tests"
version = "$(sed -n 's/^version = "\(.*\)"/\1/p' "$rust/Cargo.toml" | head -1)"
edition = "2024"
publish = false

[dependencies]
serde_json = "1"
libc = "0.2"

[dev-dependencies]
rstest = { version = "0.28.0", default-features = false }
tempfile = "3"
TOML
cd "$rust"
IETS_BIN="$bin" CARGO_TARGET_DIR="$crate/target" nix develop -c \
  cargo test --offline --no-fail-fast --manifest-path "$crate/Cargo.toml" $(printf -- '--test %s ' "${tests[@]}") -- "$@"
