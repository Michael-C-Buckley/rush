#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RUSH="$ROOT/zig-out/bin/rush"
CORPUS_DIR=${1:-$ROOT/test/corpus/posix}

zig build --summary none >/dev/null

if [ ! -d "$CORPUS_DIR" ]; then
  echo "missing POSIX corpus directory: $CORPUS_DIR" >&2
  exit 1
fi

failures=0
cases=0
for case_dir in "$CORPUS_DIR"/*; do
  [ -d "$case_dir" ] || continue
  name=$(basename "$case_dir")
  script=$case_dir/script
  expected_status=$case_dir/status
  expected_stdout=$case_dir/stdout
  expected_stderr=$case_dir/stderr

  for required in "$script" "$expected_status" "$expected_stdout" "$expected_stderr"; do
    if [ ! -f "$required" ]; then
      echo "FAIL [$name]: missing $(basename "$required")" >&2
      failures=$((failures + 1))
      continue 2
    fi
  done

  cases=$((cases + 1))
  tmp=$(mktemp -d)
  actual_stdout=$tmp/stdout
  actual_stderr=$tmp/stderr

  rush_args=
  if [ -f "$case_dir/args" ]; then
    rush_args=$(cat "$case_dir/args")
  fi
  # shellcheck disable=SC2086 # corpus args are controlled one-word CLI flags
  (cd "$tmp" && "$RUSH" $rush_args -c "$(cat "$script")" >"$actual_stdout" 2>"$actual_stderr") || actual_status=$?
  actual_status=${actual_status:-0}
  want_status=$(cat "$expected_status")

  if [ "$actual_status" -ne "$want_status" ] || ! cmp -s "$expected_stdout" "$actual_stdout" || ! cmp -s "$expected_stderr" "$actual_stderr"; then
    failures=$((failures + 1))
    echo "FAIL [$name]" >&2
    echo "  status: got $actual_status want $want_status" >&2
    echo "  expected stdout:" >&2; sed 's/^/    /' "$expected_stdout" >&2
    echo "  actual stdout:" >&2; sed 's/^/    /' "$actual_stdout" >&2
    echo "  expected stderr:" >&2; sed 's/^/    /' "$expected_stderr" >&2
    echo "  actual stderr:" >&2; sed 's/^/    /' "$actual_stderr" >&2
  fi

  rm -rf "$tmp"
  unset actual_status
done

if [ "$failures" -ne 0 ]; then
  echo "$failures POSIX corpus failure(s)" >&2
  exit 1
fi

echo "POSIX corpus passed ($cases cases)"
