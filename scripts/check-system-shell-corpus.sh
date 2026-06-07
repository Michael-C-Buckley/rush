#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RUSH="$ROOT/zig-out/bin/rush"
CORPUS=${1:-$ROOT/test/corpus/system-shell-supported.txt}

zig build --summary none >/dev/null

shells=""
for shell in dash bash; do
  if command -v "$shell" >/dev/null 2>&1; then
    shells="$shells $shell"
  fi
done

if [ -z "$shells" ]; then
  echo "no comparison shells found; expected dash and/or bash" >&2
  exit 1
fi

failures=0
case_no=0
while IFS= read -r script || [ -n "$script" ]; do
  case "$script" in
    ''|'#'*) continue ;;
  esac
  case_no=$((case_no + 1))
  for shell in $shells; do
    tmp=$(mktemp -d)
    rush_out=$tmp/rush.out
    rush_err=$tmp/rush.err
    shell_out=$tmp/shell.out
    shell_err=$tmp/shell.err

    (cd "$tmp" && "$RUSH" -c "$script" >"$rush_out" 2>"$rush_err") || rush_status=$?
    rush_status=${rush_status:-0}
    (cd "$tmp" && "$shell" -c "$script" >"$shell_out" 2>"$shell_err") || shell_status=$?
    shell_status=${shell_status:-0}

    if [ "$rush_status" -ne "$shell_status" ] || ! cmp -s "$rush_out" "$shell_out" || ! cmp -s "$rush_err" "$shell_err"; then
      failures=$((failures + 1))
      echo "FAIL [$shell] case $case_no: $script" >&2
      echo "  rush status=$rush_status shell status=$shell_status" >&2
      echo "  rush stdout:" >&2; sed 's/^/    /' "$rush_out" >&2
      echo "  shell stdout:" >&2; sed 's/^/    /' "$shell_out" >&2
      echo "  rush stderr:" >&2; sed 's/^/    /' "$rush_err" >&2
      echo "  shell stderr:" >&2; sed 's/^/    /' "$shell_err" >&2
    fi
    rm -rf "$tmp"
    unset rush_status shell_status
  done
done < "$CORPUS"

if [ "$failures" -ne 0 ]; then
  echo "$failures corpus comparison failure(s)" >&2
  exit 1
fi

echo "system shell corpus passed ($case_no cases across:$shells)"
