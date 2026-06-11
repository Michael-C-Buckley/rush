# POSIX builtin compliance submatrix

This submatrix expands builtin-related rows in `posix-shell.tsv`. It separates POSIX special builtins, regular utilities, Rush helper builtins, and job-control utilities so implementation work can target options, operands, diagnostics, and shell-error consequences deliberately.

## Summary

| group | current state | primary gaps |
| --- | --- | --- |
| POSIX special builtins | classification, assignment persistence, and error consequences supported | utility-specific breadth remains on broad builtin rows |
| Core regular builtins | broad baseline for common scripts | option/operand completeness and negative diagnostics |
| Job-control builtins | background job table, wait baseline, jobs/kill operands, fg/bg, stopped jobs | remaining pipeline/asynchronous-list signal edge cases |
| Rush helper builtins | useful implementation helpers | keep out of POSIX score unless they affect shell semantics |

## POSIX special builtins

Special builtins matter because POSIX assigns special consequences to expansion and redirection errors, and assignment prefixes may persist.

| utility | manifest rows | current coverage | gaps |
| --- | --- | --- | --- |
| `:` | `builtin-colon` | `basic-colon`, `builtin-colon-special-assignment`, special-builtin expansion/redirection consequences | none for the narrow special-builtin consequence row |
| `.` | `builtin-dot`, `builtin-dot-current-env`, `builtin-dot-path-search`, `builtin-dot-usage-errors` | current-shell effects, PATH search, missing/nonexistent/non-readable file diagnostics and unit coverage | broader file loading edge cases |
| `break`, `continue` | `builtin-break-continue`, `builtin-loop-control-nested-levels`, `builtin-loop-control-outside-loop`, `builtin-loop-control-usage-errors` | basic loop control, nested levels, outside-loop and operand diagnostic negative corpus | deeper mixed compound-command edge cases |
| `eval` | `builtin-eval`, `builtin-eval-arguments` | basic eval, argument concatenation, empty eval status, special assignment persistence, parse/expansion/redirection failure consequences | broader diagnostics edge cases |
| `exec` | `builtin-exec`, `builtin-exec-redirection-only` | `builtin-exec`, `builtin-exec-assignment-env`, `builtin-exec-failure-exits`, `builtin-exec-replaces-process`, current-shell redirection-only exec | permission-denied failure status details, no-return contexts |
| `exit` | `builtin-exit`, `builtin-exit-status-default`, `builtin-exit-usage-errors` | explicit/default status, invalid-operand, and too-many diagnostics with non-interactive exit | additional nested contexts |
| `export` | `builtin-export-unset`, `builtin-export-readonly-p`, `builtin-export-readonly-p-reusable`, `builtin-variable-usage-errors` | `builtin-export-env`, `export -p`, reusable quoted values, invalid-name, readonly-assignment, unsupported-option, and `-p` usage diagnostics | broader reusable listing edge cases |
| `readonly` | `vars-readonly`, `builtin-export-readonly-p`, `builtin-export-readonly-p-reusable`, `builtin-variable-usage-errors` | `builtin-readonly`, `readonly -p`, reusable quoted values, invalid-name, readonly-assignment, unsupported-option, and `-p` usage diagnostics | broader reusable listing edge cases |
| `return` | `builtin-return-status-default`, `builtin-return-usage-errors` plus function tests | explicit status, default previous-status behavior, outside-function, invalid-operand, and too-many diagnostics | additional nested function edge cases |
| `set` | `option-set`, `option-set-short-clusters`, `option-set-allexport`, `option-set-o-listing`, `option-set-plus-o-listing`, `builtin-set-positionals`, `option-set-usage-errors`, `option-set-obsolescent-noop`, `option-set-ignoreeof`, option rows | shell option, allexport, clustered short option, `$-` flag reflection including monitor/-m and notify/-b state, set - option reset, no-operand variable listing, set -o/+o option listing and reusable re-input smoke, set -- positional parameter corpus, option parsing followed by positional operands, obsolescent no-effect `-h`/`nolog` compatibility, interactive `ignoreeof`, interactive `notify` polling while the editor is active, monitor-mode process groups for tracked interactive async jobs, and invalid option diagnostics | vi and complete job-control terminal edge cases |
| `shift` | `builtin-shift-operands`, `builtin-shift-too-far`, `builtin-shift-usage-errors` | default and explicit count operands, too-far status, invalid operand, and too-many diagnostics | additional function/top-level interaction edge cases |
| `times` | `builtin-times`, `builtin-times-usage-errors` | resource usage output shape, centisecond formatting, getrusage-backed shell/child accounting, plus excess-operand diagnostics with non-interactive exit | exact CPU totals are runtime- and host-dependent, so corpus coverage validates shape rather than fixed values |
| `trap` | `builtin-trap`, `builtin-trap-invalid-signal`, `signal-trap-real` | reusable listing output, reset and null-ignore actions, EXIT, INT signal corpus, invalid signal diagnostics with non-interactive exit; real signal dispatch covers ignored-at-entry non-interactive signals, caught-trap reset in subshells and command substitutions, trap status preservation, wait interruption, and process-directed trapped signals waking/redrawing the active editor | broader implementation-specific signal name coverage beyond tracked catchable signals |
| `unset` | `builtin-export-unset`, `builtin-unset-default-variable`, `builtin-unset-variable-function`, `builtin-variable-usage-errors` | default variable mode, unset -v, unset -f, invalid-name, readonly-variable, and unsupported-option coverage with non-interactive exit for failures | broader unset utility edges |

High-risk rows:

- `errors-special-builtin` — supported after the all-special-builtin utility-error audit.
- `errors-special-builtin-redirection`
- `errors-special-builtin-expansion`
- `builtin-special`

## Regular POSIX utilities implemented as builtins

| utility | manifest rows | current coverage | gaps |
| --- | --- | --- | --- |
| `alias`, `unalias` | `builtin-alias`, `builtin-unalias-all`, `builtin-alias-usage-errors`, alias lexing rows | POSIX-format list/query output, reusable value quoting, POSIX alias-name operands, remove, unalias -a, unalias --, invalid-name/not-found diagnostics, reserved-word/function-name protection | parser-level alias substitution timing remains tracked by `lex-alias-token-timing`, not the supported builtin utility row |
| `cd`, `pwd` | `builtin-cd-pwd`, `builtin-cd-logical-physical`, `builtin-cd-logical-dotdot`, `builtin-cd-usage-errors`, `builtin-pwd-logical-physical`, `builtin-pwd-usage-errors`, `vars-pwd` | logical PWD/OLDPWD, CDPATH, cd -, cd -L/-P, logical symlink dot-dot, pwd -L/-P, and cd/pwd usage diagnostics | deeper cd path diagnostics |
| `command` | `builtin-command`, `builtin-command-multiple-lookup`, `builtin-command-function-suppression`, `builtin-command-option-terminator`, `builtin-command-usage-errors` | `-p`, `-v`, `-V`, multiple lookup operands, `--`, function lookup suppression, option and lookup operand diagnostics | edge cases around special builtins, utilities, PATH errors |
| `env` | `builtin-env`, `builtin-env-option-terminator`, `builtin-env-usage-errors` | `-i`, `--`, assignments, command execution, printing, invalid option and command-not-found diagnostics | additional command propagation edge cases |
| `getopts` | `builtin-getopts`, `builtin-getopts-explicit-args`, `builtin-getopts-option-terminator`, `builtin-getopts-optind-reset`, `builtin-getopts-usage-errors` | clusters, required args, silent missing arg, explicit args, `--` termination, OPTIND reset, invalid optstring and variable-name diagnostics | remaining getopts edge cases |
| `printf` | `builtin-printf`, `builtin-printf-usage-errors`, printf subrows | escapes, `%b`/`%c`, format reuse, octal/hex, width/precision, missing format, invalid format/conversion, invalid numeric operand diagnostics | full POSIX format grammar and locale details |
| `read` | `builtin-read`, read subrows | backslash, `-r`, `--`, custom/mixed/empty IFS, last-variable remainder assignment, EOF status, option/operand diagnostics, and PTY coverage for interactive terminal input plus literal `PS2` continuation prompts | none known for tracked POSIX read utility behavior |
| `test`, `[` | `builtin-test`, test subrows | POSIX-defined argument-count grammar, file predicates including symlinks, terminal fds, mode bits, and special file types, string comparisons, integer comparisons, ordering, bracket close diagnostics, and invalid expression status | historical `-a`/`-o`/parenthesized expression compatibility is retained but excluded from the POSIX.1-2024 claim because Issue 8 removed those operators |
| `umask` | `builtin-umask`, `builtin-umask-symbolic-output`, `builtin-umask-symbolic-operands`, `builtin-umask-usage-errors` | basic get/set, current-shell effects, subshell and pipeline isolation, created-file permission effect, `-S` symbolic output, symbolic mask operands including chmod-style multiple actions, permission copies and conditional `X`, invalid numeric/symbolic masks, unsupported options, excess operands | none known for POSIX permission bits |
| `wait` | `builtin-wait`, `builtin-wait-usage-errors` | tracked pid wait, all-job no-operand wait status, last-operand status, current/previous/numeric/prefix/substring job ID operands, stopped-job blocking, trapped-signal interruption, invalid/unknown pid diagnostics using status 127 | broader diagnostic wording differences vs other shells |

## Job-control builtins

| utility | manifest rows | current coverage | gaps |
| --- | --- | --- | --- |
| `jobs` | `builtin-jobs`; `job-stopped-state` | POSIX-spaced visible table, `-l`, `-p`, numeric, `%`, `%+`, `%%`, `%-`, prefix, and substring job operands; current/previous markers; nonblocking stopped/done status refresh; notifications; empty subshell and command-substitution tables; completed-job cleanup after reported termination status | remaining signal edge cases are tracked outside the supported `jobs` row |
| `fg` | `job-fg-bg`; `job-stopped-state` | monitor-enabled current, previous, numeric, prefix, and substring tracked jobs wait, propagate status, get terminal handoff when a saved process group exists, send stopped jobs `SIGCONT`, restore stopped-job terminal modes, and remove completed foreground jobs from the waitable table | remaining signal edge cases are tracked outside the supported `fg`/`bg` row |
| `bg` | `job-fg-bg`; `job-stopped-state` | monitor-enabled current, previous, numeric, prefix, substring, and multiple tracked jobs report with POSIX `[%d] %s` output; stopped jobs get `SIGCONT`; repeated stopped notifications can be reported after a continue; disabled job control reports an error | remaining signal edge cases are tracked outside the supported `fg`/`bg` row |
| `kill` | `builtin-kill` | default `TERM`, `-s signal`, `-signal`, `-0`, ordinary pid operands, and current, previous, numeric, prefix, and substring job ID operands; tracked jobs are signaled by process group when available | broader implementation-specific signal list/output formatting remains intentionally minimal |

Follow-up tasks:

- remaining job-control follow-up work is in pipeline/asynchronous-list signal edge cases rather than the supported `fg`/`bg` and stopped-state utility rows.

## Negative diagnostics coverage targets

The POSIX negative corpus covers representative builtin diagnostics for `test`, `read`, `wait`, `kill`, POSIX special builtin usage failures, `getopts`, `printf`, and `umask`, including non-octal numeric mask syntax. Remaining broad builtin rows should add focused negative cases when implementing their listed option and operand gaps.

## Promotion guidance

Builtin rows should usually stay `baseline` while they are broad utility-level rows. Promote smaller `spec_clause` rows first, such as individual `test` predicate groups or `read -r` behavior, after unit, POSIX corpus, and negative corpus evidence exists. Special-builtin consequence rows require non-interactive exit behavior plus negative corpus coverage before support claims.
