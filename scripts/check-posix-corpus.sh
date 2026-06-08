#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RUSH="$ROOT/zig-out/bin/rush"
CORPUS_DIR=${1:-$ROOT/test/corpus/posix}
CORPUS_LABEL=${CORPUS_LABEL:-POSIX corpus}

zig build --summary none >/dev/null

if [ ! -d "$CORPUS_DIR" ]; then
  echo "missing POSIX corpus directory: $CORPUS_DIR" >&2
  exit 1
fi

metadata=$CORPUS_DIR/METADATA.tsv
metadata_seen=
if [ -f "$metadata" ]; then
  expected_header='case	area	tags	notes'
  actual_header=$(sed -n '1p' "$metadata")
  if [ "$actual_header" != "$(printf '%b' "$expected_header")" ]; then
    echo "invalid POSIX corpus metadata header" >&2
    exit 1
  fi
  metadata_seen=$(mktemp)
  line_no=0
  tab=$(printf '\t')
  while IFS="$tab" read -r case_name area tags notes extra; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    if [ -n "${extra:-}" ]; then
      echo "metadata line $line_no: too many columns" >&2
      exit 1
    fi
    if [ -z "${case_name:-}" ] || [ -z "${area:-}" ] || [ -z "${tags:-}" ] || [ -z "${notes:-}" ]; then
      echo "metadata line $line_no: empty required column" >&2
      exit 1
    fi
    case "$area" in
      lexing|grammar|expansion|redirection|builtin|job_control|signals|options|errors|variables|portability|extensions) ;;
      *) echo "metadata line $line_no: invalid area: $area" >&2; exit 1 ;;
    esac
    if grep -Fx -- "$case_name" "$metadata_seen" >/dev/null; then
      echo "metadata line $line_no: duplicate case: $case_name" >&2
      exit 1
    fi
    if [ ! -d "$CORPUS_DIR/$case_name" ]; then
      echo "metadata line $line_no: missing case directory: $case_name" >&2
      exit 1
    fi
    printf '%s\n' "$case_name" >>"$metadata_seen"
  done <"$metadata"
fi

failures=0
cases=0
times_stdout_matches() {
  [ "$(wc -l <"$1" | tr -d ' ')" -eq 2 ] || return 1
  grep -Eq '^[0-9]+m[0-9]+\.[0-9][0-9]s [0-9]+m[0-9]+\.[0-9][0-9]s$' "$1"
}

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

  if [ -n "$metadata_seen" ] && ! grep -Fx -- "$name" "$metadata_seen" >/dev/null; then
    echo "FAIL [$name]: missing metadata row" >&2
    failures=$((failures + 1))
    continue
  fi

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

  stdout_ok=false
  if cmp -s "$expected_stdout" "$actual_stdout"; then
    stdout_ok=true
  elif [ "$name" = builtin-times ] && times_stdout_matches "$actual_stdout"; then
    stdout_ok=true
  fi

  if [ "$actual_status" -ne "$want_status" ] || [ "$stdout_ok" != true ] || ! cmp -s "$expected_stderr" "$actual_stderr"; then
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

if [ -n "$metadata_seen" ]; then rm -f "$metadata_seen"; fi

echo "$CORPUS_LABEL passed ($cases cases)"
