#!/usr/bin/env sh
set -eu

# Worker mode: invoked by xargs below with a single corpus case name.
# Runs the case against Rush and compares status/stdout/stderr.
# Inherits CORPUS_DIR, RUSH, FAILDIR from the parent environment.
if [ -n "${RUSH_CORPUS_WORKER:-}" ]; then
  name=$1
  case_dir=$CORPUS_DIR/$name

  requirements_status() {
    [ -f "$case_dir/requires" ] || return 0

    status=0
    while IFS= read -r requirement || [ -n "$requirement" ]; do
      case "$requirement" in
        ''|'#'*) ;;
        os:linux)
          [ "$(uname -s)" = Linux ] || status=1
          ;;
        path:*)
          path=${requirement#path:}
          [ -e "$path" ] || status=1
          ;;
        *)
          echo "FAIL [$name]: unsupported requirement: $requirement" >"$FAILDIR/$name"
          return 2
          ;;
      esac
    done <"$case_dir/requires"

    return "$status"
  }

  times_stdout_matches() {
    [ "$(wc -l <"$1" | tr -d ' ')" -eq 2 ] || return 1
    grep -Eq '^[0-9]+m[0-9]+\.[0-9][0-9]s [0-9]+m[0-9]+\.[0-9][0-9]s$' "$1"
  }

  for required in script status stdout stderr; do
    if [ ! -f "$case_dir/$required" ]; then
      echo "FAIL [$name]: missing $required" >"$FAILDIR/$name"
      exit 1
    fi
  done

  requirements=0
  requirements_status || requirements=$?
  if [ "$requirements" -eq 2 ]; then
    exit 1
  fi
  if [ "$requirements" -ne 0 ]; then
    echo "SKIP [$name]: unmet requirements" >"$SKIPDIR/$name"
    exit 0
  fi

  tmp=$(mktemp -d)
  actual_stdout=$tmp/stdout
  actual_stderr=$tmp/stderr

  rush_args=
  if [ -f "$case_dir/args" ]; then
    rush_args=$(cat "$case_dir/args")
  fi
  actual_status=0
  # shellcheck disable=SC2086 # corpus args are controlled one-word CLI flags
  (cd "$tmp" && "$RUSH" $rush_args -c "$(cat "$case_dir/script")" >"$actual_stdout" 2>"$actual_stderr") || actual_status=$?
  want_status=$(cat "$case_dir/status")

  stdout_ok=false
  if cmp -s "$case_dir/stdout" "$actual_stdout"; then
    stdout_ok=true
  elif [ "$name" = builtin-times ] && times_stdout_matches "$actual_stdout"; then
    stdout_ok=true
  fi

  status=0
  if [ "$actual_status" -ne "$want_status" ] || [ "$stdout_ok" != true ] || ! cmp -s "$case_dir/stderr" "$actual_stderr"; then
    status=1
    {
      echo "FAIL [$name]"
      echo "  status: got $actual_status want $want_status"
      echo "  expected stdout:"; sed 's/^/    /' "$case_dir/stdout"
      echo "  actual stdout:"; sed 's/^/    /' "$actual_stdout"
      echo "  expected stderr:"; sed 's/^/    /' "$case_dir/stderr"
      echo "  actual stderr:"; sed 's/^/    /' "$actual_stderr"
    } >"$FAILDIR/$name"
  fi

  rm -rf "$tmp"
  exit "$status"
fi

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RUSH="$ROOT/zig-out/bin/rush"
CORPUS_DIR=${1:-$ROOT/test/corpus/posix}
CORPUS_LABEL=${CORPUS_LABEL:-POSIX corpus}

if [ -z "${RUSH_SKIP_BUILD:-}" ]; then
  zig build --summary none >/dev/null
fi

if [ ! -d "$CORPUS_DIR" ]; then
  echo "missing POSIX corpus directory: $CORPUS_DIR" >&2
  exit 1
fi
CORPUS_DIR=$(CDPATH= cd -- "$CORPUS_DIR" && pwd)

workdir=$(mktemp -d)
FAILDIR=$workdir/failures
SKIPDIR=$workdir/skips
mkdir "$FAILDIR"
mkdir "$SKIPDIR"
trap 'rm -rf "$workdir"' EXIT

metadata=$CORPUS_DIR/METADATA.tsv
metadata_seen=
if [ -f "$metadata" ]; then
  metadata_seen=$workdir/metadata-names
  awk -F '\t' '
    NR == 1 {
      if ($0 != "case\tarea\ttags\tnotes") {
        print "invalid POSIX corpus metadata header" > "/dev/stderr"
        bad = 1
        exit 1
      }
      next
    }
    NF > 4 { printf "metadata line %d: too many columns\n", NR > "/dev/stderr"; bad = 1; next }
    $1 == "" || $2 == "" || $3 == "" || $4 == "" {
      printf "metadata line %d: empty required column\n", NR > "/dev/stderr"; bad = 1; next
    }
    $2 !~ /^(lexing|grammar|expansion|redirection|builtin|job_control|signals|options|errors|variables|portability|extensions)$/ {
      printf "metadata line %d: invalid area: %s\n", NR, $2 > "/dev/stderr"; bad = 1; next
    }
    seen[$1]++ { printf "metadata line %d: duplicate case: %s\n", NR, $1 > "/dev/stderr"; bad = 1; next }
    { print $1 }
    END { exit bad }
  ' "$metadata" >"$metadata_seen"
  while IFS= read -r case_name; do
    if [ ! -d "$CORPUS_DIR/$case_name" ]; then
      echo "missing case directory: $case_name" >&2
      exit 1
    fi
  done <"$metadata_seen"
fi

for case_dir in "$CORPUS_DIR"/*; do
  [ -d "$case_dir" ] || continue
  printf '%s\n' "${case_dir##*/}"
done >"$workdir/all-cases"

if [ -n "$metadata_seen" ]; then
  sort "$metadata_seen" >"$workdir/meta-sorted"
  sort "$workdir/all-cases" >"$workdir/cases-sorted"
  comm -23 "$workdir/cases-sorted" "$workdir/meta-sorted" | while IFS= read -r name; do
    echo "FAIL [$name]: missing metadata row" >"$FAILDIR/$name"
  done
  comm -12 "$workdir/cases-sorted" "$workdir/meta-sorted" >"$workdir/case-names"
else
  cp "$workdir/all-cases" "$workdir/case-names"
fi
cases=$(wc -l <"$workdir/case-names" | tr -d ' ')

JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
export CORPUS_DIR RUSH FAILDIR SKIPDIR

if [ "$cases" -gt 0 ]; then
  xargs -P "$JOBS" -n 1 env RUSH_CORPUS_WORKER=1 sh "$0" <"$workdir/case-names" || true
fi

failures=$(find "$FAILDIR" -type f | wc -l | tr -d ' ')
if [ "$failures" -ne 0 ]; then
  cat "$FAILDIR"/* >&2
  echo "$failures POSIX corpus failure(s)" >&2
  exit 1
fi

skips=$(find "$SKIPDIR" -type f | wc -l | tr -d ' ')
if [ "$skips" -ne 0 ]; then
  echo "$CORPUS_LABEL passed ($cases cases, $skips skipped)"
else
  echo "$CORPUS_LABEL passed ($cases cases)"
fi
