# External POSIX shell test suite evaluation

Rush uses local unit tests, expected-output POSIX corpus cases, negative diagnostics, and differential comparison shells as the primary compliance signal. External suites are useful, but they should be imported selectively so Rush does not inherit another shell's extension expectations or brittle diagnostics.

## Selection criteria

Import external tests only when they are:

- portable across Linux, macOS, and BSD runners;
- focused on POSIX shell language or POSIX utility behavior Rush implements internally;
- deterministic without timing-sensitive job-control assumptions;
- licensed compatibly with the Rush repository;
- representable as expected-output or differential corpus cases with stable status/stdout/stderr;
- small enough to debug when a single imported case fails.

Avoid importing tests that require a particular `/bin/sh`, assume GNU utilities, depend on interactive terminal state, or assert implementation-specific diagnostics unless they are moved into `posix-negative` as Rush-specific behavior.

## Candidate suites

| source | fit | useful slices | risks | recommendation |
| --- | --- | --- | --- | --- |
| dash tests | high | POSIX parser, expansion, redirection, functions, builtins | may assume dash diagnostics or implementation quirks | import small language-focused slices after license review |
| BusyBox ash tests | medium | embedded-shell compatibility, builtins, redirection, expansion | BusyBox test harness and utility assumptions can be broad | mine individual scripts rather than vendoring the harness |
| bash POSIX-mode tests | medium | Bash compatibility deltas, POSIX mode behavior | Bash still has Bash-specific behavior and diagnostics | use as comparison/reference, not direct conformance source |
| posix shell snippets from Open POSIX Testsuite / LTP-style tests | medium | utility and shell-language smoke tests | often assumes system utilities and harness conventions | import only isolated shell-language cases |
| shellspec-style community examples | low/medium | readable behavior examples | frequently tests framework semantics, not POSIX | translate manually into Rush corpus cases when valuable |
| Austin Group defect/regression examples | high for specific clauses | exact spec edge cases and ambiguity decisions | examples are not a ready-to-run suite | add as hand-curated spec-clause corpus cases |

## Import strategy

1. Keep external suites out of the default build until cases are curated.
2. Convert each selected case into one of the existing Rush layers:
   - `test/corpus/posix` for Rush/spec expected output;
   - `test/corpus/system-shell-supported.txt` only when comparison shells agree;
   - `test/corpus/posix-negative` for diagnostics or shell-error consequences.
3. Tag imported positive cases in `test/corpus/posix/METADATA.tsv` by compliance area.
4. Link imported cases from `test/compliance/posix-shell.tsv` only after the case is stable in CI.
5. Prefer many tiny scripts over a copied upstream harness.

## First import slices

### Dash-derived language smoke cases

Target rows:

- `grammar-case`
- `grammar-function`
- `grammar-loop`
- `grammar-subshell`
- `redirection-basic`

Imported starter slice:

- `dash-smoke-function-redirection`
- `dash-smoke-subshell-env`
- `dash-smoke-loop-case`

These are hand-translated POSIX language smoke cases, not vendored dash harness files. They are also present in the differential corpus after comparison across the available shells.

Further import plan:

- review dash test licensing and attribution requirements before copying any upstream text;
- select additional language-only tests with no dash-only diagnostics;
- translate each to Rush expected-output corpus cases;
- add differential entries only for cases confirmed across dash, BusyBox ash, bash POSIX mode, and yash when available.

### BusyBox ash redirection and builtin cases

Target rows:

- `redirection-basic`
- `builtin-test`
- `builtin-read`
- `builtin-printf`

Imported starter slice:

- `busybox-ash-smoke-printf-redirection`
- `busybox-ash-smoke-test-redirection`
- `busybox-ash-smoke-read-redirection`

These are hand-translated BusyBox ash-style smoke cases, not vendored BusyBox harness files. They are also present in the differential corpus after comparison across the available shells.

Further import plan:

- mine individual simple scripts rather than running the BusyBox harness;
- keep BusyBox-specific applet assumptions out of Rush tests;
- place diagnostic cases in `posix-negative` only if Rush intentionally matches the behavior.

### Austin Group/spec-clause examples

Target rows:

- `expansion-pathname-slash-components`
- `grammar-case-empty-arms`
- `errors-special-builtin-expansion`
- `option-errexit-conditions`

Import plan:

- hand-curate examples directly from POSIX wording or defect-resolution notes;
- add comments in corpus metadata notes that reference the relevant manifest row;
- avoid treating these as external conformance certification.

## Not recommended yet

- Running an entire upstream shell test harness in `zig build`.
- Tests requiring a controlling TTY until Rush has stopped-job and terminal mode restoration coverage.
- Tests that assert exact diagnostics across multiple shells.
- Large utility suites where the shell is only the harness language.

## Follow-up tasks

Create separate tasks for each curated import slice so failures remain attributable:

1. Import a dash-derived POSIX language smoke slice.
2. Import BusyBox ash-inspired redirection and builtin corpus cases.
3. Add Austin Group/spec-clause examples for current high-risk manifest gaps.
4. Add optional external-suite fetch/provision documentation if vendoring or local checkout support becomes useful.
