# POSIX shell compliance manifest

`posix-shell.tsv` is the machine-readable source of truth for Rush POSIX shell compliance tracking. It complements `POSIX_AUDIT.md`: the audit explains the current state in prose, while this manifest is intended for metrics, dashboards, and follow-up task planning.

## Schema

The file is tab-separated UTF-8 with one header row and these columns:

1. `id` — stable lowercase identifier for the checklist item.
2. `area` — broad compliance area, such as `lexing`, `grammar`, `expansion`, `redirection`, `builtin`, `job_control`, `signals`, or `errors`.
3. `posix_ref` — concrete POSIX.1 XCU Shell Command Language or utility reference where practical; POSIX-adjacent and non-POSIX rows should say so explicitly.
4. `feature` — human-readable feature description.
5. `status` — one of:
   - `supported`: implemented with meaningful tests or corpus coverage.
   - `baseline`: useful implementation exists, but important POSIX edge cases remain.
   - `partial`: recognizable implementation exists, but significant semantics are missing.
   - `missing`: not implemented or placeholder-only.
   - `out_of_scope`: POSIX-adjacent or intentionally deferred.
6. `posix_corpus` — semicolon-separated `test/corpus/posix` case directory names, or `-`.
7. `differential_corpus` — semicolon-separated differential corpus references, currently usually `system-shell-supported` or `-`.
8. `granularity` — one of:
   - `coarse`: broad feature bucket that should eventually be split into smaller rows.
   - `detailed`: focused subfeature row with meaningful implementation and coverage boundaries.
   - `spec_clause`: row mapped closely to a specific POSIX clause or requirement.
9. `risk` — one of:
   - `low`: unlikely to hide major POSIX-incompatible behavior.
   - `medium`: useful behavior exists but edge cases are likely.
   - `high`: correctness-sensitive, broad, partial, or missing behavior that can materially affect conformance.
10. `notes` — concise notes without tabs or newlines.

Run `scripts/check-compliance-manifest.sh` to validate the TSV shape and referenced POSIX corpus directories.

Run `scripts/report-compliance.sh` or `zig build compliance` to summarize conformance progress. The checklist scores are planning heuristics, not formal POSIX certification:

- `strict_supported_only`: only `supported` rows count.
- `practical_supported_baseline`: `supported` plus `baseline` rows count.
- `weighted_progress`: `supported=1.0`, `baseline=0.7`, `partial=0.3`, and `missing=0.0`.

`out_of_scope` rows are excluded from score denominators. Corpus pass counts report the current test inventory only; they do not imply complete POSIX coverage.

The `granularity` and `risk` fields are intended to prevent false confidence. A 100% score over mostly `coarse` rows is weaker than a 100% score over `detailed` or `spec_clause` rows, and high-risk baseline rows should usually be expanded before being promoted to `supported`.

The report includes confidence-oriented sections:

- `Compliance by granularity` shows how much of the checklist is still broad versus detailed/spec-clause level.
- `Compliance by risk` separates high-risk semantic areas from low-risk helper behavior.
- `Confidence matrix by granularity and risk` shows whether progress is concentrated in detailed low-risk rows or coarse/high-risk rows.
- `High-risk open items` lists non-supported high-risk rows that should generally receive implementation or submatrix work first.
- `Coarse open items` lists broad rows that should be split before their status is treated as strong conformance evidence.

## POSIX corpus metadata

`test/corpus/posix/METADATA.tsv` tags each expected-output corpus case with an area and tags. The POSIX corpus runner validates that every case directory has exactly one metadata row and that metadata rows point at existing case directories.

Metadata columns:

1. `case` — case directory name under `test/corpus/posix`.
2. `area` — same broad area vocabulary used by the compliance manifest.
3. `tags` — semicolon-separated tags such as `behavior`, `negative`, `builtin`, `option`, `here-doc`, or `job`.
4. `notes` — concise notes, or `-`.

The compliance report uses this metadata to print POSIX corpus case counts by area.

## Expansion submatrix

`expansion-submatrix.md` tracks POSIX expansion phases, current corpus coverage, known gaps, and follow-up tasks. Use it when adding expansion corpus cases or changing parameter, command substitution, arithmetic, field splitting, pathname, or quote-removal behavior.

## Builtin submatrix

`builtin-submatrix.md` tracks POSIX special builtins, regular utility builtins, job-control builtins, Rush helper builtins, and their diagnostic/operand gaps. Use it when changing builtin behavior or adding negative builtin corpus cases.

## External test suites

`external-test-suites.md` evaluates dash, BusyBox ash, Bash POSIX-mode, LTP/Open POSIX-style snippets, shellspec-style examples, and spec-clause examples for selective Rush corpus import. Use it before vendoring or translating any external suite.

## Spec-clause examples

`spec-clause-examples.md` records hand-curated POSIX examples added for high-risk manifest rows, including pathname, case grammar, special-builtin expansion consequences, and errexit contexts.

## Error consequence submatrix

`error-consequences.md` tracks syntax, expansion, redirection, special-builtin, and builtin diagnostic consequences separately from normal behavior coverage. Use it when adding negative corpus cases or implementing stricter POSIX shell-error behavior.

## Dash variable audit

`dash-variable-audit.md` records permissively licensed dash source findings for shell-maintained variables such as `IFS`, `PWD`, `PPID`, `LINENO`, prompts, `OPTIND`, and interactive-only variables. Use it before changing shell startup environment behavior or creating variable-related POSIX follow-up tasks.

## Status promotion criteria

Manifest status changes should be evidence-based. When in doubt, use the lower status and record the remaining gap in `notes`.

### `missing`

Use `missing` when Rush has no implementation, only placeholder behavior, or rejects the feature entirely. A row can leave `missing` only when there is executable behavior plus at least one unit test or corpus case showing the intended baseline.

### `partial`

Use `partial` when Rush has recognizable behavior but significant POSIX semantics are absent or knowingly wrong. Typical `partial` rows have one or more of:

- implementation exists for only a narrow happy path;
- major operands, options, grammar branches, or error consequences are absent;
- behavior is known to diverge from POSIX for common scripts;
- no POSIX expected-output corpus coverage exists yet;
- high-risk behavior is still represented by a coarse row.

Promote `partial` to `baseline` when the common behavior works, meaningful unit or POSIX corpus coverage exists, and remaining gaps are edge cases documented in `notes` or follow-up Tend tasks.

### `baseline`

Use `baseline` when Rush implements useful, script-relevant behavior and has meaningful test coverage, but the row is not yet exhaustive enough for `supported`. A `baseline` row should normally have:

- unit coverage or POSIX expected-output corpus coverage;
- differential corpus coverage when comparison shells agree and diagnostics are stable enough;
- documented remaining POSIX edge cases in `notes`;
- no known failures for the common behavior described by `feature`.

Keep a row at `baseline` instead of `supported` when it is `coarse`, `high` risk, or represents a utility/semantic area with many untracked subrequirements.

### `supported`

Use `supported` only when the row is narrow enough and covered enough that we are comfortable treating it as implemented for the tracked POSIX requirement. A `supported` row should have:

- `granularity=detailed` or `granularity=spec_clause`, except for genuinely small low-risk features;
- unit coverage for parser/executor internals where applicable;
- POSIX expected-output corpus coverage for externally visible behavior;
- differential corpus coverage when comparison shells agree;
- negative/error coverage when the feature includes diagnostics or shell-error consequences;
- no known untracked high-risk edge cases in `notes`.

High-risk rows should generally not be promoted to `supported` until they have been split into detailed or spec-clause subitems and those subitems have coverage.

### `out_of_scope`

Use `out_of_scope` for POSIX-adjacent extensions or intentionally deferred UX/Bash features that should not affect POSIX conformance scoring. Keep completion, prompt, editor, and Bash-only features out of POSIX score denominators unless they directly affect POSIX shell semantics.

## Coverage expectations

- **Unit tests** prove internal parser, expansion, or executor mechanics.
- **POSIX corpus cases** prove Rush's expected externally visible behavior.
- **Differential corpus cases** prove agreement with available comparison shells where portable agreement exists.
- **Negative corpus cases** live under `test/corpus/posix-negative` and are required before error-heavy rows can be considered `supported`. Cases may use a `requires` file for platform-specific evidence, such as Linux-only `/dev/full` write failures, while remaining skipped on unsupported hosts.
- **Cross-target compile checks** are required for portability-sensitive implementation changes, but they do not replace runtime POSIX behavior tests.
