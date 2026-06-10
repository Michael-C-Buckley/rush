#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MANIFEST=${1:-$ROOT/test/compliance/posix-shell.tsv}
CORPUS_DIR=$ROOT/test/corpus/posix

if [ ! -f "$MANIFEST" ]; then
  echo "missing compliance manifest: $MANIFEST" >&2
  exit 1
fi

# Single awk pass validates row shape and enums, and emits the corpus case
# references (which need directory checks the shell does below) as
# CASE<tab>line<tab>name records alongside ERR<tab>message records.
findings=$(mktemp)
trap 'rm -f "$findings"' EXIT

awk -F '\t' '
  function err(msg) { printf "ERR\t%s\n", msg }
  NR == 1 {
    if ($0 != "id\tarea\tposix_ref\tfeature\tstatus\tposix_corpus\tdifferential_corpus\tgranularity\trisk\tnotes") {
      err("invalid compliance manifest header")
      err("got:  " $0)
      err("want: id\tarea\tposix_ref\tfeature\tstatus\tposix_corpus\tdifferential_corpus\tgranularity\trisk\tnotes")
      exit
    }
    next
  }
  NF > 10 { err(sprintf("line %d: too many columns", NR)); next }
  {
    for (i = 1; i <= 10; i++) {
      if ($i == "") { err(sprintf("line %d: empty required column", NR)); next }
    }
  }
  seen[$1]++ { err(sprintf("line %d: duplicate id: %s", NR, $1)) }
  $5 !~ /^(supported|baseline|partial|missing|out_of_scope)$/ { err(sprintf("line %d: invalid status: %s", NR, $5)) }
  $8 !~ /^(coarse|detailed|spec_clause)$/ { err(sprintf("line %d: invalid granularity: %s", NR, $8)) }
  $9 !~ /^(low|medium|high)$/ { err(sprintf("line %d: invalid risk: %s", NR, $9)) }
  $6 != "-" {
    n = split($6, cases, ";")
    for (i = 1; i <= n; i++) printf "CASE\t%d\t%s\n", NR, cases[i]
  }
' "$MANIFEST" >"$findings"

failures=0
tab=$(printf '\t')
while IFS="$tab" read -r kind field1 field2; do
  case "$kind" in
    ERR)
      # field2 is non-empty only when the message itself contains tabs.
      if [ -n "${field2:-}" ]; then
        printf '%s\t%s\n' "$field1" "$field2" >&2
      else
        echo "$field1" >&2
      fi
      failures=$((failures + 1))
      ;;
    CASE)
      if [ ! -d "$CORPUS_DIR/$field2" ]; then
        echo "line $field1: missing POSIX corpus case: $field2" >&2
        failures=$((failures + 1))
      fi
      ;;
  esac
done <"$findings"

if [ "$failures" -ne 0 ]; then
  echo "$failures compliance manifest failure(s)" >&2
  exit 1
fi

rows=$(($(wc -l <"$MANIFEST") - 1))
echo "compliance manifest valid ($rows rows)"
