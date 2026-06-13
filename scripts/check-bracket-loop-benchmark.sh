#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RUSH=${RUSH:-${1:-$ROOT/zig-out/bin/rush}}
case $RUSH in
  /*|*/*)
    RUSH=$(CDPATH= cd -- "$(dirname -- "$RUSH")" && pwd)/$(basename -- "$RUSH")
    ;;
esac

if [ -z "${RUSH_SKIP_BUILD:-}" ]; then
  zig build --summary none >/dev/null
fi

LOOPS=${RUSH_BRACKET_BENCH_LOOPS:-100}
ENTRIES=${RUSH_BRACKET_BENCH_ENTRIES:-20000}
RUNS=${RUSH_BRACKET_BENCH_RUNS:-3}
MAX_PERCENT=${RUSH_BRACKET_BENCH_MAX_PERCENT:-150}
# Timing checks should catch the old directory-scan regression without failing
# when a CI host has a noisy scheduler tick. The entry-heavy cwd above keeps the
# regressed case well beyond this absolute allowance.
SLACK_SECONDS=${RUSH_BRACKET_BENCH_SLACK_SECONDS:-0.30}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

i=0
while [ "$i" -lt "$ENTRIES" ]; do
  : >"$tmp/f$i"
  i=$((i + 1))
done

bracket_script="i=0; while [ \$i -lt $LOOPS ]; do i=\$((i+1)); done"
test_script="i=0; while test \$i -lt $LOOPS; do i=\$((i+1)); done"

run_time() {
  label=$1
  script=$2
  sample=$3
  stdout=$tmp/$label.$sample.out
  stderr=$tmp/$label.$sample.err

  if ! (cd "$tmp" && /usr/bin/time -p "$RUSH" -c "$script" >"$stdout" 2>"$stderr"); then
    cat "$stderr" >&2
    echo "bracket loop benchmark: $label sample $sample failed" >&2
    exit 1
  fi
  if [ -s "$stdout" ]; then
    echo "bracket loop benchmark: $label sample $sample produced output" >&2
    sed 's/^/stdout: /' "$stdout" >&2
    exit 1
  fi
  awk '
    $1 == "real" && NF == 2 { real = $2; found = 1; next }
    ($1 == "user" || $1 == "sys") && NF == 2 { next }
    { bad = 1 }
    END { if (bad || !found) exit 1; print real }
  ' "$stderr" || {
    echo "bracket loop benchmark: $label sample $sample produced unexpected stderr" >&2
    sed 's/^/stderr: /' "$stderr" >&2
    exit 1
  }
}

samples=$tmp/samples.tsv
: >"$samples"
run=1
while [ "$run" -le "$RUNS" ]; do
  printf 'test\t%s\n' "$(run_time test "$test_script" "$run")" >>"$samples"
  printf 'bracket\t%s\n' "$(run_time bracket "$bracket_script" "$run")" >>"$samples"
  run=$((run + 1))
done

awk -v max_percent="$MAX_PERCENT" -v slack="$SLACK_SECONDS" -v loops="$LOOPS" -v entries="$ENTRIES" '
  $1 == "test" { if (!test_seen || $2 < test_min) test_min = $2; test_seen = 1 }
  $1 == "bracket" { if (!bracket_seen || $2 < bracket_min) bracket_min = $2; bracket_seen = 1 }
  END {
    if (!test_seen || !bracket_seen) {
      print "bracket loop benchmark: missing timing samples" > "/dev/stderr"
      exit 1
    }
    limit = test_min * max_percent / 100 + slack
    ratio = (test_min > 0) ? bracket_min / test_min : 0
    printf "bracket loop benchmark: [ %.2fs, test %.2fs, ratio %.2fx, limit %.2fs (%d loops, %d cwd entries)\n", bracket_min, test_min, ratio, limit, loops, entries
    if (bracket_min > limit) {
      printf "bracket loop benchmark failed: [ loop %.2fs exceeds test loop %.2fs * %.2f + %.2fs\n", bracket_min, test_min, max_percent / 100, slack > "/dev/stderr"
      exit 1
    }
  }
' "$samples"
