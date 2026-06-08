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

printf 'POSIX conformance progress\n'
printf '===========================\n'
printf 'manifest: %s\n' "${MANIFEST#$ROOT/}"
printf 'note: checklist scores are planning heuristics, not formal POSIX certification\n'

awk -F '\t' '
NR > 1 {
  total++
  status[$5]++
}
END {
  supported = status["supported"] + 0
  baseline = status["baseline"] + 0
  partial = status["partial"] + 0
  missing = status["missing"] + 0
  out_of_scope = status["out_of_scope"] + 0
  scored = total - out_of_scope
  strict = scored == 0 ? 0 : supported * 100 / scored
  practical = scored == 0 ? 0 : (supported + baseline) * 100 / scored
  weighted = scored == 0 ? 0 : (supported + baseline * 0.7 + partial * 0.3) * 100 / scored

  printf "tracked_items:       %d\n", total
  printf "scored_posix_items:  %d\n", scored
  printf "status.supported:    %d\n", supported
  printf "status.baseline:     %d\n", baseline
  printf "status.partial:      %d\n", partial
  printf "status.missing:      %d\n", missing
  printf "status.out_of_scope: %d\n", out_of_scope
  printf "\nChecklist scores\n"
  printf "strict_supported_only:      %.1f%%\n", strict
  printf "practical_supported_baseline: %.1f%%\n", practical
  printf "weighted_progress:          %.1f%%\n", weighted
  printf "score_weights: supported=1.0 baseline=0.7 partial=0.3 missing=0.0\n"
}
' "$MANIFEST"

print_status_table() {
  title=$1
  key_column=$2
  printf '\n%s\n' "$title"
  printf 'group\ttotal\tsupported\tbaseline\tpartial\tmissing\tout_of_scope\n'
  awk -F '\t' -v key_column="$key_column" '
  NR > 1 {
    group = $key_column
    totals[group]++
    key = group SUBSEP $5
    counts[key]++
  }
  END {
    for (name in totals) names[++n] = name
    for (i = 1; i <= n; i++) {
      for (j = i + 1; j <= n; j++) {
        if (names[j] < names[i]) {
          tmp = names[i]; names[i] = names[j]; names[j] = tmp
        }
      }
    }
    for (i = 1; i <= n; i++) {
      name = names[i]
      printf "%s\t%d\t%d\t%d\t%d\t%d\t%d\n", name, totals[name], counts[name SUBSEP "supported"] + 0, counts[name SUBSEP "baseline"] + 0, counts[name SUBSEP "partial"] + 0, counts[name SUBSEP "missing"] + 0, counts[name SUBSEP "out_of_scope"] + 0
    }
  }
  ' "$MANIFEST"
}

print_status_table 'Compliance by area' 2
print_status_table 'Compliance by granularity' 8
print_status_table 'Compliance by risk' 9

printf '\nConfidence matrix by granularity and risk\n'
printf 'granularity\trisk\ttotal\tsupported\tbaseline\tpartial\tmissing\tout_of_scope\n'
awk -F '\t' '
NR > 1 {
  group = $8 SUBSEP $9
  totals[group]++
  counts[group SUBSEP $5]++
}
END {
  for (group in totals) groups[++n] = group
  for (i = 1; i <= n; i++) {
    for (j = i + 1; j <= n; j++) {
      if (groups[j] < groups[i]) {
        tmp = groups[i]; groups[i] = groups[j]; groups[j] = tmp
      }
    }
  }
  for (i = 1; i <= n; i++) {
    split(groups[i], parts, SUBSEP)
    group = groups[i]
    printf "%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\n", parts[1], parts[2], totals[group], counts[group SUBSEP "supported"] + 0, counts[group SUBSEP "baseline"] + 0, counts[group SUBSEP "partial"] + 0, counts[group SUBSEP "missing"] + 0, counts[group SUBSEP "out_of_scope"] + 0
  }
}
' "$MANIFEST"

printf '\nHigh-risk open items\n'
printf 'id\tarea\tstatus\tgranularity\tfeature\n'
awk -F '\t' '
NR > 1 && $9 == "high" && $5 != "supported" && $5 != "out_of_scope" {
  printf "%s\t%s\t%s\t%s\t%s\n", $1, $2, $5, $8, $4
}
' "$MANIFEST"

printf '\nCoarse open items\n'
printf 'id\tarea\tstatus\trisk\tfeature\n'
awk -F '\t' '
NR > 1 && $8 == "coarse" && $5 != "supported" && $5 != "out_of_scope" {
  printf "%s\t%s\t%s\t%s\t%s\n", $1, $2, $5, $9, $4
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
