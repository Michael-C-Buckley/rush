# POSIX shell error consequence submatrix

This submatrix tracks Rush behavior for POSIX shell errors separately from normal behavior coverage. It is intentionally narrower than `POSIX_AUDIT.md` and is meant to guide negative corpus growth and implementation tasks such as special-builtin error consequences.

## Status legend

- **covered baseline**: Rush has a defined behavior and negative corpus coverage.
- **covered gap**: Rush behavior is captured, but known POSIX consequences are incomplete.
- **uncovered gap**: known high-risk area without dedicated negative corpus coverage.

## Current negative corpus and unit evidence

| case | area | status | current consequence |
| --- | --- | --- | --- |
| `syntax-missing-pipeline-command` | syntax | covered baseline | parse diagnostic, status 2, no execution |
| `expansion-nounset-unset-parameter` | expansion | covered baseline | diagnostic, status 1, non-interactive execution stops |
| `expansion-parameter-error-word` | expansion | covered baseline | diagnostic word expansion, status 1, non-interactive execution stops |
| `expansion-parameter-error-null` | expansion | covered baseline | null parameter with `:?` diagnostic, status 1, non-interactive execution stops |
| `expansion-parameter-error-word-spaces` | expansion | covered baseline | unquoted multi-word diagnostic, status 1, non-interactive execution stops |
| `expansion-parameter-error-null-spaces` | expansion | covered baseline | null parameter with unquoted multi-word diagnostic, status 1, non-interactive execution stops |
| `expansion-parameter-assign-positional-*` / `expansion-parameter-assign-special-*` | expansion | covered baseline | `${parameter:=word}` / `${parameter=word}` cannot assign to positional or special parameters when assignment would be needed; diagnostic, status 1, non-interactive execution stops |
| `expansion-redirection-target-error` | expansion | covered baseline | redirection target word expansion failure reports the diagnostic and exits non-interactive execution before running a following command |
| `expansion-assignment-word-error` | expansion | covered baseline | assignment word expansion failure reports the diagnostic and exits non-interactive execution before applying or running a following command |
| `expansion-for-list-error` | expansion | covered baseline | for-loop word-list expansion failure reports the diagnostic and exits non-interactive execution before running the loop body or a following command |
| `expansion-case-subject-error` / `expansion-case-pattern-error` | expansion | covered baseline | case subject and pattern expansion failures report the diagnostic and exit non-interactive execution before selecting an arm or running a following command |
| `expansion-command-substitution-arithmetic-error` | expansion | covered baseline | nested arithmetic diagnostic is surfaced; assignment-only status follows failed substitution |
| `expansion-command-substitution-parameter-error` | expansion | covered baseline | nested parameter expansion diagnostics are surfaced from the command-substitution subshell; the subshell exits before later substitution commands, while the invoking shell continues and assignment-only status follows the substitution |
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
| inherited broken-pipe fd unit tests | output write | covered baseline | after `>&fd` setup succeeds, shell-implemented builtins diagnose `write: broken pipe`, return status 1, functions/brace groups expose status 1, and pipelines record failed stage status including `pipefail` and last-stage cases |
| `output-write-failure-dev-full-statuses` | output write | covered baseline | Linux-gated `/dev/full` negative corpus covers actual output file target write failures for builtin, function, brace group, external, and pipeline status paths while being skipped on platforms without `/dev/full` |
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
| `errors-expansion` | supported | high | nounset, `${parameter:?word}`, malformed braced parameter substitutions, arithmetic including invalid variable values, redirection-target, assignment-word, for-list, case subject/pattern, command-substitution, and interactive unit coverage | expansion failures exit non-interactive execution in current-shell contexts; failures inside command-substitution subshells exit only that subshell and propagate diagnostics/status; interactive execution aborts the current command without setting shell exit |
| `errors-special-builtin` | supported | high | assignment persistence plus negative coverage for redirection, expansion, and utility-specific failures | all 15 POSIX special builtins have audited non-interactive shell-exit consequences for invalid options or operands where applicable and utility-semantic failures |
| `errors-nounset` | supported | high | POSIX and negative corpus | unset parameter failures stop non-interactive execution, with default-operator and disable behavior covered separately |
| `errors-redirection-noninteractive` | supported | high | POSIX and negative corpus | consolidated with the former `redirection-error-consequences` row; ordinary utility, compound, function, `<>`, here-doc materialization, async, pipeline, AND-OR, negation, `$?`, and `errexit` consequences are covered. Rush uses status 1 for most non-special redirection failures where dash often uses 2; both are documented as conforming non-zero statuses. |
| `errors-output-write-failure` | supported | high | unit tests and Linux-gated negative corpus | a portable broken-pipe fd harness covers write failures after redirection setup/open succeeds, and a gated `/dev/full` case covers actual file targets where available; shell-implemented commands diagnose and return non-zero, pipelines record stage status, and external utility write failures are delegated to the child process |
| `errors-special-builtin-redirection` | supported | high | negative corpus | noclobber, missing input, bad input/output fd, and directory output special-builtin redirection failures exit non-interactive execution across representative POSIX special builtins |
| `errors-special-builtin-expansion` | supported | high | negative corpus | ${parameter:?word} and nounset special-builtin expansion failures exit non-interactive execution across `:`, `eval`, `export`, `readonly`, `set`, `unset`, and `trap` |

The former manifest row `redirection-error-consequences` had no distinct scope after comparison with `errors-redirection-noninteractive`: both tracked XCU 2.8.1 redirection error consequences for non-interactive shells. The merged `errors-redirection-noninteractive` row owns ordinary command status propagation through AND-OR lists, negation, pipelines, `$?`, and `errexit`, as well as the broader special-builtin versus non-special shell-exit matrix.

## POSIX consequence areas to expand

### Syntax errors

Current coverage includes a missing pipeline command, malformed case items, malformed if/for/while/until/function constructs including invalid for loop variables, missing grouping terminators, unterminated quote/substitution forms, missing redirection targets, here-doc delimiter diagnostics, and strict-mode reserved-word placement. Some parser diagnostics are intentionally recovery-oriented outside strict mode.

### Expansion errors

Current coverage includes nounset and `${parameter:?word}` with diagnostic word expansion for unset and null parameters, including unquoted multi-word braced words. Malformed or unsupported braced parameter substitutions such as `${}`/`${v/}`/`${v:1}` report `parameter: bad substitution` and stop non-interactive execution. Assignment parameter expansion forms report `cannot assign in this way` and stop non-interactive execution when `${parameter:=word}` or `${parameter=word}` would need to assign to a positional or special parameter. Arithmetic expansion syntax and unsupported semantic forms report a shell diagnostic and stop non-interactive execution. Negative corpus coverage now includes expansion failures in redirection target words, assignment words, for-loop word lists, case subjects and patterns, and command substitutions. Command substitutions run in a subshell for error-consequence purposes: nested expansion failures stop that subshell, surface diagnostics, preserve assignment-only substitution status, and let the invoking shell continue. Unit coverage verifies interactive expansion failures abort the current command without setting `pending_exit`, allowing the prompt loop to continue.

### Redirection errors

Current coverage includes bad input/output fd duplication, noclobber, missing input redirection targets, directory output failures, missing redirection operands, `<>` open failures, compound and function redirection consequences, pipeline status propagation, AND-OR/negation/`$?`, `errexit` interactions, here-doc delimiter diagnostics, and here-doc fd materialization failures. Redirected output write failures after successful setup/open are covered by unit tests using a shell-visible fd duplicated from a broken pipe, plus a Linux-gated `/dev/full` negative corpus case for actual file target failures. Rush status values intentionally track POSIX's non-zero requirement rather than dash's exact status 2 convention for many redirection errors.

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
- redirected output write failures after setup succeeds: shell-implemented builtins/functions/compound commands use status 1 with a `write` diagnostic when Rush observes the failed write; pipeline status follows the failed stage and normal `pipefail`/last-stage rules; external command status and diagnostics come from the child utility or signal termination;
- signal termination: not yet represented in negative corpus.

## Follow-up implementation targets

- `#147 Add negative POSIX diagnostics corpus` seeded the first corpus slice; future cases should extend it.
- Add follow-up tasks when a new negative case documents a known Rush/POSIX gap rather than implemented behavior.
