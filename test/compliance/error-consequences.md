# POSIX shell error consequence submatrix

This submatrix tracks Rush behavior for POSIX shell errors separately from normal behavior coverage. It is intentionally narrower than `POSIX_AUDIT.md` and is meant to guide negative corpus growth and implementation tasks such as special-builtin error consequences.

## Status legend

- **covered baseline**: Rush has a defined behavior and negative corpus coverage.
- **covered gap**: Rush behavior is captured, but known POSIX consequences are incomplete.
- **uncovered gap**: known high-risk area without dedicated negative corpus coverage.

## Current negative corpus

| case | area | status | current consequence |
| --- | --- | --- | --- |
| `syntax-missing-pipeline-command` | syntax | covered baseline | parse diagnostic, status 2, no execution |
| `expansion-nounset-unset-parameter` | expansion | covered baseline | diagnostic, status 1, non-interactive execution stops |
| `redirection-bad-fd-duplication` | redirection | covered gap | diagnostic, command fails, following command still runs |
| `redirection-noclobber-overwrite` | redirection | covered gap | diagnostic, command fails, following command still runs |
| `builtin-test-invalid-expression` | builtin diagnostics | covered baseline | diagnostic, builtin status 2, following command runs |
| `builtin-read-unsupported-option` | builtin diagnostics | covered baseline | diagnostic, builtin status 2, following command runs |
| `builtin-wait-unknown-pid` | builtin diagnostics | covered baseline | diagnostic, builtin status 127, following command runs |

## Manifest rows

| manifest row | status | risk | coverage | notes |
| --- | --- | --- | --- | --- |
| `errors-command-not-found` | supported | medium | POSIX and differential corpus | simple not-found and unknown wait pid behavior are covered |
| `errors-syntax` | baseline | high | POSIX corpus and negative corpus | strict mode has initial diagnostics; recovery parser remains intentionally permissive for tooling |
| `errors-expansion` | partial | high | nounset coverage only | `${parameter:?word}` and special-builtin expansion consequences remain incomplete |
| `errors-special-builtin` | partial | high | assignment persistence coverage only | shell-exit consequences for failures are not modeled in detail |
| `errors-nounset` | baseline | high | POSIX and negative corpus | unset parameter failures stop non-interactive execution in current baseline |
| `errors-redirection-noninteractive` | partial | high | POSIX and negative corpus | diagnostics exist; shell-exit and special-builtin consequences need stricter modeling |
| `errors-special-builtin-redirection` | partial | high | no dedicated negative corpus | needs cases for special builtin redirection failures |
| `errors-special-builtin-expansion` | partial | high | no dedicated negative corpus | needs cases for special builtin expansion failures |

## POSIX consequence areas to expand

### Syntax errors

Current coverage starts with a missing pipeline command. Additional cases should cover malformed compound commands, malformed case items, missing redirection targets, unmatched grouping tokens, and strict-mode reserved-word placement. Some parser diagnostics are intentionally recovery-oriented outside strict mode.

### Expansion errors

Current coverage includes nounset. Add negative cases for `${parameter:?word}` with unset and null parameters, including word expansion in diagnostics. Distinguish ordinary command failures from special builtin expansion failures because POSIX assigns different non-interactive shell consequences.

### Redirection errors

Current coverage includes bad fd duplication and noclobber. Add cases for missing redirection targets, permission failures where portable, directory output failures where portable, here-doc delimiter diagnostics, and redirection failures attached to special builtins.

### Special builtin failures

High-risk and under-covered. Add cases for `: >bad`, `eval`, `export`, `readonly`, `set`, `unset`, `trap`, and other POSIX special builtins where expansion or redirection fails. Track whether non-interactive execution should stop and whether assignment side effects persist.

### Regular builtin failures

Current coverage includes `test`, `read`, and `wait`. Add cases for `printf` invalid formats, `getopts` invalid usage, `shift` too far, `return` outside functions, `break`/`continue` outside loops, `env` invalid options, and command lookup failures where diagnostics are stable.

### Exit status classes

Track expected status families separately:

- syntax and usage errors: commonly 2 in Rush baseline;
- command not found: 127;
- command not executable/permission denied: 126 where implemented;
- expansion/redirection failures: currently mixed and should be tightened by context;
- signal termination: not yet represented in negative corpus.

## Follow-up implementation targets

- `#155 Improve parameter error expansion diagnostics`
- `#156 Model POSIX special builtin error consequences`
- `#147 Add negative POSIX diagnostics corpus` seeded the first corpus slice; future cases should extend it.
- Add follow-up tasks when a new negative case documents a known Rush/POSIX gap rather than implemented behavior.
