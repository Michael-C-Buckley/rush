# POSIX shell compliance manifest

`posix-shell.tsv` is the machine-readable source of truth for Rush POSIX shell compliance tracking. It complements `POSIX_AUDIT.md`: the audit explains the current state in prose, while this manifest is intended for metrics, dashboards, and follow-up task planning.

## Schema

The file is tab-separated UTF-8 with one header row and these columns:

1. `id` — stable lowercase identifier for the checklist item.
2. `area` — broad compliance area, such as `lexing`, `grammar`, `expansion`, `redirection`, `builtin`, `job_control`, `signals`, or `errors`.
3. `posix_ref` — short POSIX Shell Command Language reference.
4. `feature` — human-readable feature description.
5. `status` — one of:
   - `supported`: implemented with meaningful tests or corpus coverage.
   - `baseline`: useful implementation exists, but important POSIX edge cases remain.
   - `partial`: recognizable implementation exists, but significant semantics are missing.
   - `missing`: not implemented or placeholder-only.
   - `out_of_scope`: POSIX-adjacent or intentionally deferred.
6. `posix_corpus` — semicolon-separated `test/corpus/posix` case directory names, or `-`.
7. `differential_corpus` — semicolon-separated differential corpus references, currently usually `system-shell-supported` or `-`.
8. `notes` — concise notes without tabs or newlines.

Run `scripts/check-compliance-manifest.sh` to validate the TSV shape and referenced POSIX corpus directories.
