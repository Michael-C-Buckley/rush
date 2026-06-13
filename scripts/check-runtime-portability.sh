#!/usr/bin/env sh
set -eu

ZIG=${ZIG:-zig}
export ZIG
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

host_os=$(uname -s 2>/dev/null || echo unknown)
host_machine=$(uname -m 2>/dev/null || echo unknown)
zig_version=$($ZIG version 2>/dev/null || echo unknown)

case "$host_os" in
  Linux|FreeBSD|OpenBSD|NetBSD|Darwin) ;;
  *)
    echo "warning: untracked runtime portability host: $host_os $host_machine" >&2
    ;;
esac

echo "runtime-portability host: $host_os $host_machine"
echo "runtime-portability zig: $zig_version"

echo "runtime-check compliance manifest"
sh scripts/check-compliance-manifest.sh

echo "runtime-check POSIX expected-output corpus"
sh scripts/check-posix-corpus.sh

echo "runtime-check POSIX negative corpus"
sh scripts/check-posix-negative-corpus.sh

echo "runtime-check system-shell differential corpus"
sh scripts/check-system-shell-corpus.sh

echo "runtime-check native build test"
$ZIG build test --summary none
