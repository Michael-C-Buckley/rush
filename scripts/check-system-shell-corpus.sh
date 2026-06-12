#!/usr/bin/env sh
set -eu

# Worker mode: invoked by xargs below with a single corpus line number.
# Runs Rush once, then compares its output against each shell in $SHELLS.
# Inherits CORPUS, RUSH, SHELLS, FAILDIR from the parent environment.
if [ -n "${RUSH_CORPUS_WORKER:-}" ]; then
  lineno=$1
  script=$(sed -n "${lineno}p" "$CORPUS")
  decoded_script=$(printf '%b' "$script")
  tmp=$(mktemp -d)
  status=0

  mkdir "$tmp/rush"
  rush_status=0
  (cd "$tmp/rush" && "$RUSH" -c "$decoded_script" >"$tmp/rush.out" 2>"$tmp/rush.err") || rush_status=$?

  for label in $SHELLS; do
    case "$label" in
      dash) set -- dash ;;
      bash-posix) set -- bash --posix ;;
    esac

    mkdir "$tmp/$label"
    shell_status=0
    (cd "$tmp/$label" && "$@" -c "$decoded_script" >"$tmp/shell.out" 2>"$tmp/shell.err") || shell_status=$?

    if [ "$rush_status" -ne "$shell_status" ] || ! cmp -s "$tmp/rush.out" "$tmp/shell.out" || ! cmp -s "$tmp/rush.err" "$tmp/shell.err"; then
      status=1
      {
        echo "FAIL [$label] line $lineno: $script"
        echo "  rush status=$rush_status shell status=$shell_status"
        echo "  rush stdout:"; sed 's/^/    /' "$tmp/rush.out"
        echo "  shell stdout:"; sed 's/^/    /' "$tmp/shell.out"
        echo "  rush stderr:"; sed 's/^/    /' "$tmp/rush.err"
        echo "  shell stderr:"; sed 's/^/    /' "$tmp/shell.err"
      } >"$FAILDIR/$(printf '%06d' "$lineno").$label"
    fi
  done

  rm -rf "$tmp"
  exit "$status"
fi

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RUSH="$ROOT/zig-out/bin/rush"
CORPUS=${1:-$ROOT/test/corpus/system-shell-supported.txt}

if [ -z "${RUSH_SKIP_BUILD:-}" ]; then
  zig build --summary none >/dev/null
fi

SHELLS=""
if command -v dash >/dev/null 2>&1; then SHELLS="$SHELLS dash"; fi
if command -v bash >/dev/null 2>&1; then SHELLS="$SHELLS bash-posix"; fi
SHELLS=${SHELLS# }

if [ -z "$SHELLS" ]; then
  echo "no comparison shells found; expected dash or bash" >&2
  exit 1
fi

FAILDIR=$(mktemp -d)
trap 'rm -rf "$FAILDIR"' EXIT

JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
export CORPUS RUSH SHELLS FAILDIR

cases=$(awk '$0 != "" && substr($0, 1, 1) != "#" { n++ } END { print n + 0 }' "$CORPUS")
awk '$0 != "" && substr($0, 1, 1) != "#" { print NR }' "$CORPUS" |
  xargs -P "$JOBS" -n 1 env RUSH_CORPUS_WORKER=1 sh "$0" || true

failures=$(find "$FAILDIR" -type f | wc -l | tr -d ' ')
if [ "$failures" -ne 0 ]; then
  cat "$FAILDIR"/* >&2
  echo "$failures corpus comparison failure(s)" >&2
  exit 1
fi

set -- $SHELLS
comparisons=$((cases * $#))
echo "system shell corpus passed ($cases cases, $comparisons comparisons across: $SHELLS)"
