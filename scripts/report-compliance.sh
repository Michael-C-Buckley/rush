#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MANIFEST=${MANIFEST:-$ROOT/test/compliance/posix-shell.tsv}
POSIX_CORPUS_DIR=${POSIX_CORPUS_DIR:-$ROOT/test/corpus/posix}
DIFF_CORPUS=${DIFF_CORPUS:-$ROOT/test/corpus/system-shell-supported.txt}
RUN_CORPORA=0

case "${1:-}" in
  --run-corpora) RUN_CORPORA=1 ;;
  "") ;;
  *)
    echo "usage: $0 [--run-corpora]" >&2
    exit 2
    ;;
esac

"$ROOT/scripts/check-compliance-manifest.sh" "$MANIFEST" >/dev/null

printf 'POSIX compliance manifest\n'
printf '=========================\n'
printf 'manifest: %s\n' "${MANIFEST#$ROOT/}"

awk -F '\t' '
NR > 1 {
  total++
  status[$5]++
}
END {
  printf "tracked_items: %d\n", total
  split("supported baseline partial missing out_of_scope", statuses, " ")
  for (i = 1; i <= length(statuses); i++) {
    name = statuses[i]
    printf "status.%-12s %d\n", name ":", status[name] + 0
  }
}
' "$MANIFEST"

printf '\nCompliance by area\n'
printf 'area\ttotal\tsupported\tbaseline\tpartial\tmissing\tout_of_scope\n'
awk -F '\t' '
NR > 1 {
  area[$2]++
  key = $2 SUBSEP $5
  counts[key]++
}
END {
  for (name in area) names[++n] = name
  for (i = 1; i <= n; i++) {
    for (j = i + 1; j <= n; j++) {
      if (names[j] < names[i]) {
        tmp = names[i]; names[i] = names[j]; names[j] = tmp
      }
    }
  }
  for (i = 1; i <= n; i++) {
    name = names[i]
    printf "%s\t%d\t%d\t%d\t%d\t%d\t%d\n", name, area[name], counts[name SUBSEP "supported"] + 0, counts[name SUBSEP "baseline"] + 0, counts[name SUBSEP "partial"] + 0, counts[name SUBSEP "missing"] + 0, counts[name SUBSEP "out_of_scope"] + 0
  }
}
' "$MANIFEST"

posix_cases=0
if [ -d "$POSIX_CORPUS_DIR" ]; then
  posix_cases=$(find "$POSIX_CORPUS_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
fi

diff_cases=0
if [ -f "$DIFF_CORPUS" ]; then
  diff_cases=$(grep -v '^[[:space:]]*$' "$DIFF_CORPUS" | grep -v '^[[:space:]]*#' | wc -l | tr -d ' ')
fi

printf '\nCorpus inventory\n'
printf 'posix_expected_cases: %s\n' "$posix_cases"
printf 'differential_cases:  %s\n' "$diff_cases"

if [ "$RUN_CORPORA" -eq 1 ]; then
  printf '\nCorpus validation\n'
  "$ROOT/scripts/check-posix-corpus.sh" "$POSIX_CORPUS_DIR"
  "$ROOT/scripts/check-system-shell-corpus.sh" "$DIFF_CORPUS"
fi
