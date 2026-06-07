#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RUSH="$ROOT/zig-out/bin/rush"
CORPUS=${1:-$ROOT/test/corpus/system-shell-supported.txt}

zig build --summary none >/dev/null

available_shells=""
if command -v dash >/dev/null 2>&1; then available_shells="$available_shells dash"; fi
if command -v bash >/dev/null 2>&1; then available_shells="$available_shells bash bash-posix"; fi
if command -v yash >/dev/null 2>&1; then available_shells="$available_shells yash"; fi
if command -v busybox >/dev/null 2>&1; then available_shells="$available_shells busybox-ash"; fi
if command -v mksh >/dev/null 2>&1; then available_shells="$available_shells mksh"; fi

if [ -z "$available_shells" ]; then
  echo "no comparison shells found; expected one of dash, bash, yash, busybox, mksh" >&2
  exit 1
fi

failures=0
case_no=0
comparisons=0

compare_shell() {
  label=$1
  shift
  tmp=$(mktemp -d)
  rush_out=$tmp/rush.out
  rush_err=$tmp/rush.err
  shell_out=$tmp/shell.out
  shell_err=$tmp/shell.err

  (cd "$tmp" && "$RUSH" -c "$decoded_script" >"$rush_out" 2>"$rush_err") || rush_status=$?
  rush_status=${rush_status:-0}
  (cd "$tmp" && "$@" -c "$decoded_script" >"$shell_out" 2>"$shell_err") || shell_status=$?
  shell_status=${shell_status:-0}

  comparisons=$((comparisons + 1))
  if [ "$rush_status" -ne "$shell_status" ] || ! cmp -s "$rush_out" "$shell_out" || ! cmp -s "$rush_err" "$shell_err"; then
    failures=$((failures + 1))
    echo "FAIL [$label] case $case_no: $script" >&2
    echo "  rush status=$rush_status shell status=$shell_status" >&2
    echo "  rush stdout:" >&2; sed 's/^/    /' "$rush_out" >&2
    echo "  shell stdout:" >&2; sed 's/^/    /' "$shell_out" >&2
    echo "  rush stderr:" >&2; sed 's/^/    /' "$rush_err" >&2
    echo "  shell stderr:" >&2; sed 's/^/    /' "$shell_err" >&2
  fi

  rm -rf "$tmp"
  unset rush_status shell_status
}

while IFS= read -r script || [ -n "$script" ]; do
  case "$script" in
    ''|'#'*) continue ;;
  esac
  case_no=$((case_no + 1))
  decoded_script=$(printf '%b' "$script")

  if command -v dash >/dev/null 2>&1; then compare_shell dash dash; fi
  if command -v bash >/dev/null 2>&1; then
    compare_shell bash bash
    compare_shell bash-posix bash --posix
  fi
  if command -v yash >/dev/null 2>&1; then compare_shell yash yash; fi
  if command -v busybox >/dev/null 2>&1; then compare_shell busybox-ash busybox ash; fi
  if command -v mksh >/dev/null 2>&1; then compare_shell mksh mksh; fi
done < "$CORPUS"

if [ "$failures" -ne 0 ]; then
  echo "$failures corpus comparison failure(s)" >&2
  exit 1
fi

echo "system shell corpus passed ($case_no cases, $comparisons comparisons across:$available_shells)"
