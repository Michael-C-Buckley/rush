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
| `expansion-parameter-error-word` | expansion | covered baseline | diagnostic word expansion, status 1, non-interactive execution stops |
| `expansion-parameter-error-null` | expansion | covered baseline | null parameter with `:?` diagnostic, status 1, non-interactive execution stops |
| `expansion-parameter-error-word-spaces` | expansion | covered baseline | unquoted multi-word diagnostic, status 1, non-interactive execution stops |
| `expansion-parameter-error-null-spaces` | expansion | covered baseline | null parameter with unquoted multi-word diagnostic, status 1, non-interactive execution stops |
| `redirection-bad-fd-duplication` | redirection | covered gap | diagnostic, command fails, following command still runs |
| `redirection-bad-input-fd-duplication` | redirection | covered gap | diagnostic, command fails, following command still runs |
| `redirection-noclobber-overwrite` | redirection | covered gap | diagnostic, command fails, following command still runs |
| `redirection-{output,append}-directory` | redirection | covered gap | diagnostic, command fails, following command still runs |
| `errors-special-builtin-redirection` | special builtin | covered baseline | diagnostic, status 1, non-interactive execution stops |
| `errors-special-builtin-redirection-{eval,export,readonly,set,unset,trap}` | special builtin | covered baseline | noclobber diagnostic, status 1, non-interactive execution stops |
| `errors-special-builtin-redirection-{output,append}-directory` | special builtin | covered baseline | directory output diagnostic, status 1, non-interactive execution stops |
| `errors-special-builtin-redirection-bad-input-fd{-eval,-export,-readonly,-set,-unset,-trap}` | special builtin | covered baseline | bad input fd diagnostic, status 1, non-interactive execution stops |
| `errors-special-builtin-expansion` | special builtin | covered baseline | diagnostic, status 1, non-interactive execution stops |
| `errors-special-builtin-expansion-{eval,export,readonly,set,unset,trap}` | special builtin | covered baseline | `${parameter:?word}` diagnostic, status 1, non-interactive execution stops |
| `errors-special-builtin-nounset-{colon,eval,export,readonly,set,unset,trap}` | special builtin | covered baseline | nounset expansion diagnostic, status 1, non-interactive execution stops |
| `builtin-test-invalid-expression` | builtin diagnostics | covered baseline | diagnostic, builtin status 2, following command runs |
| `builtin-read-unsupported-option` | builtin diagnostics | covered baseline | diagnostic, builtin status 2, following command runs |
| `builtin-wait-unknown-pid` | builtin diagnostics | covered baseline | diagnostic, builtin status 127, following command runs |

## Manifest rows

| manifest row | status | risk | coverage | notes |
| --- | --- | --- | --- | --- |
| `errors-command-not-found` | supported | medium | POSIX and differential corpus | simple not-found and unknown wait pid behavior are covered |
| `errors-syntax` | baseline | high | POSIX corpus and negative corpus | strict mode has initial diagnostics; recovery parser remains intentionally permissive for tooling |
| `errors-expansion` | partial | high | nounset and `${parameter:?word}` coverage | ordinary and special-builtin expansion failures have baseline shell-exit coverage; more expansion classes need coverage |
| `errors-special-builtin` | partial | high | assignment persistence redirection and expansion negative coverage | additional utilities and assignment side-effect consequences need more detail |
| `errors-nounset` | baseline | high | POSIX and negative corpus | unset parameter failures stop non-interactive execution in current baseline |
| `errors-redirection-noninteractive` | partial | high | POSIX and negative corpus | bad input/output fd, noclobber, missing input, and directory output diagnostics exist; more redirection classes need stricter modeling |
| `errors-special-builtin-redirection` | supported | high | negative corpus | noclobber, missing input, bad input/output fd, and directory output special-builtin redirection failures exit non-interactive execution across representative POSIX special builtins |
| `errors-special-builtin-expansion` | supported | high | negative corpus | ${parameter:?word} and nounset special-builtin expansion failures exit non-interactive execution across `:`, `eval`, `export`, `readonly`, `set`, `unset`, and `trap` |

## POSIX consequence areas to expand

### Syntax errors

Current coverage starts with a missing pipeline command. Additional cases should cover malformed compound commands, malformed case items, missing redirection targets, unmatched grouping tokens, and strict-mode reserved-word placement. Some parser diagnostics are intentionally recovery-oriented outside strict mode.

### Expansion errors

Current coverage includes nounset and `${parameter:?word}` with diagnostic word expansion for unset and null parameters, including unquoted multi-word braced words. Distinguish ordinary command failures from special builtin expansion failures because POSIX assigns different non-interactive shell consequences.

### Redirection errors

Current coverage includes bad input/output fd duplication, noclobber, missing input redirection targets, and directory output failures. Add cases for permission failures where portable, here-doc delimiter diagnostics, and more redirection failures attached to special builtins.

### Special builtin failures

High-risk and under-covered. `:` plus `eval`, `export`, `readonly`, `set`, `unset`, and `trap` now cover baseline non-interactive exit consequences for noclobber, missing input, bad input/output fd, `${parameter:?word}`, and nounset failures. `:` also covers directory output failures. Add cases for other POSIX special builtins and for other expansion or redirection classes. Track whether non-interactive execution should stop and whether assignment side effects persist.

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

- `#156 Model POSIX special builtin error consequences`
- `#147 Add negative POSIX diagnostics corpus` seeded the first corpus slice; future cases should extend it.
- Add follow-up tasks when a new negative case documents a known Rush/POSIX gap rather than implemented behavior.
