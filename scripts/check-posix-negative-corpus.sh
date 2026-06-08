#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CORPUS_LABEL="POSIX negative corpus" exec "$ROOT/scripts/check-posix-corpus.sh" "$ROOT/test/corpus/posix-negative"
