#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MANIFEST=${1:-$ROOT/test/compliance/posix-shell.tsv}
CORPUS_DIR=$ROOT/test/corpus/posix

if [ ! -f "$MANIFEST" ]; then
  echo "missing compliance manifest: $MANIFEST" >&2
  exit 1
fi

expected_header='id	area	posix_ref	feature	status	posix_corpus	differential_corpus	granularity	risk	notes'
actual_header=$(sed -n '1p' "$MANIFEST")
if [ "$actual_header" != "$(printf '%b' "$expected_header")" ]; then
  echo "invalid compliance manifest header" >&2
  echo "got:  $actual_header" >&2
  echo "want: $(printf '%b' "$expected_header")" >&2
  exit 1
fi

failures=0
seen_ids=$(mktemp)
trap 'rm -f "$seen_ids"' EXIT
line_no=0
tab=$(printf '\t')
while IFS="$tab" read -r id area posix_ref feature status posix_corpus differential_corpus granularity risk notes extra; do
  line_no=$((line_no + 1))
  [ "$line_no" -eq 1 ] && continue

  if [ -n "${extra:-}" ]; then
    echo "line $line_no: too many columns" >&2
    failures=$((failures + 1))
    continue
  fi
  if [ -z "${id:-}" ] || [ -z "${area:-}" ] || [ -z "${posix_ref:-}" ] || [ -z "${feature:-}" ] || [ -z "${status:-}" ] || [ -z "${posix_corpus:-}" ] || [ -z "${differential_corpus:-}" ] || [ -z "${granularity:-}" ] || [ -z "${risk:-}" ] || [ -z "${notes:-}" ]; then
    echo "line $line_no: empty required column" >&2
    failures=$((failures + 1))
    continue
  fi

  if grep -Fx -- "$id" "$seen_ids" >/dev/null; then
    echo "line $line_no: duplicate id: $id" >&2
    failures=$((failures + 1))
  fi
  printf '%s\n' "$id" >>"$seen_ids"

  case "$status" in
    supported|baseline|partial|missing|out_of_scope) ;;
    *)
      echo "line $line_no: invalid status: $status" >&2
      failures=$((failures + 1))
      ;;
  esac

  case "$granularity" in
    coarse|detailed|spec_clause) ;;
    *)
      echo "line $line_no: invalid granularity: $granularity" >&2
      failures=$((failures + 1))
      ;;
  esac

  case "$risk" in
    low|medium|high) ;;
    *)
      echo "line $line_no: invalid risk: $risk" >&2
      failures=$((failures + 1))
      ;;
  esac

  if [ "$posix_corpus" != "-" ]; then
    old_ifs=$IFS
    IFS=';'
    for case_name in $posix_corpus; do
      IFS=$old_ifs
      if [ ! -d "$CORPUS_DIR/$case_name" ]; then
        echo "line $line_no: missing POSIX corpus case: $case_name" >&2
        failures=$((failures + 1))
      fi
      IFS=';'
    done
    IFS=$old_ifs
  fi
done <"$MANIFEST"

if [ "$failures" -ne 0 ]; then
  echo "$failures compliance manifest failure(s)" >&2
  exit 1
fi

rows=$((line_no - 1))
echo "compliance manifest valid ($rows rows)"
