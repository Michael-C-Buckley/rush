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
| `expansion-command-substitution-arithmetic-error` | expansion | covered baseline | nested arithmetic diagnostic is surfaced; assignment-only status follows failed substitution |
| `redirection-bad-fd-duplication` | redirection | covered baseline | diagnostic, command fails, following command still runs |
| `redirection-bad-input-fd-duplication` | redirection | covered baseline | diagnostic, command fails, following command still runs |
| `redirection-noclobber-overwrite` | redirection | covered baseline | diagnostic, command fails, following command still runs |
| `redirection-{output,append}-directory` | redirection | covered baseline | diagnostic, command fails, following command still runs |
| `redirection-compound-missing-input` | redirection | covered baseline | brace group, if, while, and for input redirection failures skip the compound body and leave `$?` non-zero while following commands run |
| `redirection-function-call-vs-body` | redirection | covered baseline | call-site/function-definition redirection failures skip the body, while redirection failures inside the function body fail only that command |
| `redirection-read-write-missing-parent` | redirection | covered baseline | `<>` open failure reports a diagnostic, fails the command, and following commands run for non-special utilities |
| `redirection-regular-builtin-missing-input` | redirection | covered baseline | regular builtin input redirection failures do not exit the non-interactive shell |
| `redirection-status-propagation` | redirection | covered baseline | redirection failure status propagates through AND-OR lists, negation, and `$?` as a non-zero command status |
| `redirection-errexit` / `redirection-errexit-suppressed-contexts` | redirection | covered baseline | redirection failures trigger `errexit` only outside suppressed AND-OR and negation contexts |
| `redirection-pipeline-missing-input-last` | redirection | covered baseline | a last-stage pipeline redirection failure determines the pipeline status and does not expose internal pipe write errors |
| `redirection-heredoc-materialization-failure` / `redirection-async-heredoc-materialization-failure` | redirection | covered baseline | here-doc fd materialization failure reports a redirection diagnostic; the async form still reports successful job submission status |
| `errors-special-builtin-redirection` | special builtin | covered baseline | diagnostic, status 1, non-interactive execution stops |
| `errors-special-builtin-redirection-{eval,export,readonly,set,unset,trap}` | special builtin | covered baseline | noclobber diagnostic, status 1, non-interactive execution stops |
| `errors-special-builtin-redirection-{output,append}-directory` | special builtin | covered baseline | directory output diagnostic, status 1, non-interactive execution stops |
| `errors-special-builtin-redirection-read-write-missing-parent` | special builtin | covered baseline | `<>` open failure on a special builtin stops non-interactive execution |
| `errors-special-builtin-redirection-bad-input-fd{-eval,-export,-readonly,-set,-unset,-trap}` | special builtin | covered baseline | bad input fd diagnostic, status 1, non-interactive execution stops |
| `errors-special-builtin-expansion` | special builtin | covered baseline | diagnostic, status 1, non-interactive execution stops |
| `errors-special-builtin-expansion-{eval,export,readonly,set,unset,trap}` | special builtin | covered baseline | `${parameter:?word}` diagnostic, status 1, non-interactive execution stops |
| `errors-special-builtin-nounset-{colon,eval,export,readonly,set,unset,trap}` | special builtin | covered baseline | nounset expansion diagnostic, status 1, non-interactive execution stops |
| `builtin-dot-non-readable` | special builtin | covered baseline | permission diagnostic, status 1, non-interactive execution stops |
| `builtin-test-invalid-expression` | builtin diagnostics | covered baseline | diagnostic, builtin status 2, following command runs |
| `builtin-read-unsupported-option` | builtin diagnostics | covered baseline | diagnostic, builtin status 2, following command runs |
| `builtin-wait-unknown-pid` | builtin diagnostics | covered baseline | diagnostic, builtin status 127, following command runs |

## Manifest rows

| manifest row | status | risk | coverage | notes |
| --- | --- | --- | --- | --- |
| `errors-command-not-found` | supported | medium | POSIX and differential corpus | simple not-found and unknown wait pid behavior are covered |
| `errors-syntax` | baseline | high | POSIX corpus and negative corpus | strict mode has initial diagnostics; recovery parser remains intentionally permissive for tooling |
| `errors-expansion` | partial | high | nounset, `${parameter:?word}`, and arithmetic negative coverage | ordinary and special-builtin expansion failures have baseline shell-exit coverage; more expansion classes need coverage |
| `errors-special-builtin` | supported | high | assignment persistence plus negative coverage for redirection, expansion, and utility-specific failures | all 15 POSIX special builtins have audited non-interactive shell-exit consequences for invalid options or operands where applicable and utility-semantic failures |
| `errors-nounset` | supported | high | POSIX and negative corpus | unset parameter failures stop non-interactive execution, with default-operator and disable behavior covered separately |
| `errors-redirection-noninteractive` | supported | high | POSIX and negative corpus | consolidated with the former `redirection-error-consequences` row; ordinary utility, compound, function, `<>`, here-doc materialization, async, pipeline, AND-OR, negation, `$?`, and `errexit` consequences are covered. Rush uses status 1 for most non-special redirection failures where dash often uses 2; both are documented as conforming non-zero statuses. |
| `errors-special-builtin-redirection` | supported | high | negative corpus | noclobber, missing input, bad input/output fd, and directory output special-builtin redirection failures exit non-interactive execution across representative POSIX special builtins |
| `errors-special-builtin-expansion` | supported | high | negative corpus | ${parameter:?word} and nounset special-builtin expansion failures exit non-interactive execution across `:`, `eval`, `export`, `readonly`, `set`, `unset`, and `trap` |

The former manifest row `redirection-error-consequences` had no distinct scope after comparison with `errors-redirection-noninteractive`: both tracked XCU 2.8.1 redirection error consequences for non-interactive shells. The merged `errors-redirection-noninteractive` row owns ordinary command status propagation through AND-OR lists, negation, pipelines, `$?`, and `errexit`, as well as the broader special-builtin versus non-special shell-exit matrix.

## POSIX consequence areas to expand

### Syntax errors

Current coverage includes a missing pipeline command, malformed case items, malformed if/for/while/until/function constructs including invalid for loop variables, missing grouping terminators, unterminated quote/substitution forms, missing redirection targets, here-doc delimiter diagnostics, and strict-mode reserved-word placement. Some parser diagnostics are intentionally recovery-oriented outside strict mode.

### Expansion errors

Current coverage includes nounset and `${parameter:?word}` with diagnostic word expansion for unset and null parameters, including unquoted multi-word braced words. Arithmetic expansion syntax and unsupported semantic forms now report a shell diagnostic and stop non-interactive execution. Distinguish ordinary command failures from special builtin expansion failures because POSIX assigns different non-interactive shell consequences.

### Redirection errors

Current coverage includes bad input/output fd duplication, noclobber, missing input redirection targets, directory output failures, missing redirection operands, `<>` open failures, compound and function redirection consequences, pipeline status propagation, AND-OR/negation/`$?`, `errexit` interactions, here-doc delimiter diagnostics, and here-doc fd materialization failures. Rush status values intentionally track POSIX's non-zero requirement rather than dash's exact status 2 convention for many redirection errors.

### Special builtin failures

The broad `errors-special-builtin` row is supported after auditing all 15 POSIX special builtins. Redirection and expansion failures cover representative special builtins, while utility-specific negative rows cover `.`, `break`, `continue`, `eval`, `exec`, `exit`, `export`, `readonly`, `return`, `set`, `shift`, `times`, `trap`, and `unset`; `:` has no utility operands and is covered through assignment, expansion, and redirection consequences. The key invariant is that these diagnostics stop non-interactive execution while preserving the utility's failure status.

### Regular builtin failures

Current coverage includes `test`, `read`, and `wait`. Add cases for `printf` invalid formats, `getopts` invalid usage, `shift` too far, `return` outside functions, `break`/`continue` outside loops, `env` invalid options, and command lookup failures where diagnostics are stable.

### Exit status classes

Track expected status families separately:

- syntax and usage errors: commonly 2 in Rush baseline;
- command not found: 127;
- command not executable/permission denied: 126 where implemented;
- expansion/redirection failures: expansion failures stop non-interactive execution; non-special redirection failures use status 1 or pipeline-stage status 2 depending on context, while special-builtin redirection failures stop the shell with non-zero status;
- signal termination: not yet represented in negative corpus.

## Follow-up implementation targets

- `#147 Add negative POSIX diagnostics corpus` seeded the first corpus slice; future cases should extend it.
- Add follow-up tasks when a new negative case documents a known Rush/POSIX gap rather than implemented behavior.
