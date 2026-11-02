#!/usr/bin/env bash
# A cold fetchTree of nixos-26.05's channel tarball into an empty input store,
# from a local file and with no daemon, so the network and substitution are
# out of it.
#
#   bench/reproduce/fetch.sh prep DIR     # download and repack, once
#   FETCH_DIR=DIR bench/reproduce/fetch.sh run [BIN...]
#
# cache.nixos.org holds the channel tarball's own tree, and a daemon would
# substitute it; so `prep` appends one file and repacks with the same zstd
# settings (level 19, 8 MiB window: 40,395,308 bytes against the original
# 40,395,247), which gives a tree no store holds. Its NAR hash depends on the
# tar metadata of the added file, so it is computed again here, with
# `iets prefetch --unpack`, and kept in DIR/narhash.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
url=https://releases.nixos.org/nixos/26.05/nixos-26.05.13164.6f06d204d8f2/nixexprs.tar.zst
case ${1:?usage: fetch.sh prep DIR | run [BIN...]} in
prep)
  d=$(realpath -m "${2:?DIR}"); mkdir -p "$d" "$d/add"; cd "$d"
  [ -f nixexprs.tar.zst ] || curl -sSfL -o nixexprs.tar.zst "$url"
  top=$(zstd -dc nixexprs.tar.zst | tar t | head -1); top=${top%/}
  zstd -dc nixexprs.tar.zst > x.tar
  mkdir -p "add/$top"; echo bench > "add/$top/zz-bench"
  tar rf x.tar -C add "$top/zz-bench"
  zstd -q -19 -T0 -f x.tar -o bench.tar.zst
  gzip -6 -c x.tar > bench.tar.gz
  "${ZIG:-$here/../zig-out-rel/bin/iets}" prefetch --unpack "file://$d/bench.tar.zst" > narhash
  echo "prepared $d, narHash $(cat narhash)"
  ;;
run)
  shift
  [ $# -gt 0 ] || set -- "$here/../zig-out-rel/bin/iets" "$here/../../iets/target/release/iets"
  for bin in "$@"; do
    echo "== $bin"
    FETCH_DIR=${FETCH_DIR:?} RUNS=${RUNS:-7} "$here/run.sh" fetch "$bin" | grep -v '^saved\|^raw'
  done
  ;;
esac
