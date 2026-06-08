#!/usr/bin/env sh
set -eu

ZIG=${ZIG:-zig}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

# Native check runs tests. Cross-target checks compile tests without running foreign binaries.
$ZIG build test --summary all

for target in \
  x86_64-linux-gnu \
  aarch64-linux-gnu \
  x86_64-macos \
  aarch64-macos \
  x86_64-freebsd \
  x86_64-openbsd \
  x86_64-netbsd
 do
  echo "compile-check $target"
  $ZIG build compile-test -Dtarget="$target" --summary none
 done
