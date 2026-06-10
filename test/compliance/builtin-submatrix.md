# POSIX builtin compliance submatrix

This submatrix expands builtin-related rows in `posix-shell.tsv`. It separates POSIX special builtins, regular utilities, Rush helper builtins, and job-control utilities so implementation work can target options, operands, diagnostics, and shell-error consequences deliberately.

## Summary

| group | current state | primary gaps |
| --- | --- | --- |
| POSIX special builtins | classification and assignment persistence baseline | failure consequences, redirection/expansion errors, utility-specific diagnostics |
| Core regular builtins | broad baseline for common scripts | option/operand completeness and negative diagnostics |
| Job-control builtins | background job table, wait baseline, jobs operands/options, fg baseline | bg, stopped jobs, terminal mode restoration |
| Rush helper builtins | useful implementation helpers | keep out of POSIX score unless they affect shell semantics |

## POSIX special builtins

Special builtins matter because POSIX assigns special consequences to expansion and redirection errors, and assignment prefixes may persist.

| utility | manifest rows | current coverage | gaps |
| --- | --- | --- | --- |
| `:` | `builtin-colon` | `basic-colon`, `builtin-colon-special-assignment` | redirection failure consequences need negative coverage |
| `.` | `builtin-dot`, `builtin-dot-current-env`, `builtin-dot-path-search`, `builtin-dot-usage-errors` | current-shell effects, PATH search, missing/nonexistent file diagnostics and unit coverage | non-readable file behavior |
| `break`, `continue` | `builtin-break-continue`, `builtin-loop-control-nested-levels`, `builtin-loop-control-outside-loop`, `builtin-loop-control-usage-errors` | basic loop control, nested levels, outside-loop and operand diagnostic negative corpus | deeper mixed compound-command edge cases |
| `eval` | `builtin-eval`, `builtin-eval-arguments` | basic eval, argument concatenation, empty eval status, special assignment persistence | parse/expansion failure consequences |
| `exec` | `builtin-exec`, `builtin-exec-redirection-only` | `builtin-exec`, `builtin-exec-assignment-env`, `builtin-exec-replaces-process`, current-shell redirection-only exec | failure status details, no-return contexts |
| `exit` | `builtin-exit`, `builtin-exit-status-default`, `builtin-exit-usage-errors` | explicit/default status, invalid-operand, and too-many diagnostics | additional nested/non-interactive consequence cases |
| `export` | `builtin-export-unset`, `builtin-export-readonly-p`, `builtin-export-readonly-p-reusable`, `builtin-variable-usage-errors` | `builtin-export-env`, `export -p`, reusable quoted values, invalid-name, readonly-assignment, unsupported-option, and `-p` usage diagnostics | broader reusable listing edge cases |
| `readonly` | `vars-readonly`, `builtin-export-readonly-p`, `builtin-export-readonly-p-reusable`, `builtin-variable-usage-errors` | `builtin-readonly`, `readonly -p`, reusable quoted values, invalid-name, readonly-assignment, unsupported-option, and `-p` usage diagnostics | broader reusable listing edge cases |
| `return` | `builtin-return-status-default`, `builtin-return-usage-errors` plus function tests | explicit status, default previous-status behavior, outside-function, invalid-operand, and too-many diagnostics | additional nested function edge cases |
| `set` | `option-set`, `option-set-short-clusters`, `option-set-allexport`, `builtin-set-positionals`, `option-set-usage-errors`, option rows | shell option, allexport, clustered short option, and set -- positional parameter corpus; invalid option diagnostics | many POSIX flags and broader operand forms |
| `shift` | `builtin-shift-operands`, `builtin-shift-too-far`, `builtin-shift-usage-errors` | default and explicit count operands, too-far status, invalid operand, and too-many diagnostics | additional function/top-level interaction edge cases |
| `times` | `builtin-times` | `builtin-times` | portability/runtime precision is baseline only |
| `trap` | `builtin-trap`, `signal-trap-real` | listing, clear, EXIT, INT signal corpus | signal semantics, ignored signals, invalid names, inheritance |
| `unset` | `builtin-export-unset`, `builtin-unset-default-variable`, `builtin-unset-variable-function`, `builtin-variable-usage-errors` | default variable mode, unset -v, unset -f, invalid-name, readonly-variable, and unsupported-option coverage | remaining special-builtin edge cases |

High-risk rows:

- `errors-special-builtin`
- `errors-special-builtin-redirection`
- `errors-special-builtin-expansion`
- `builtin-special`

Follow-up task: `#156 Model POSIX special builtin error consequences`.

## Regular POSIX utilities implemented as builtins

| utility | manifest rows | current coverage | gaps |
| --- | --- | --- | --- |
| `alias`, `unalias` | `builtin-alias`, `builtin-unalias-all`, `builtin-alias-usage-errors`, alias lexing rows | list, remove, unalias -a, invalid-name/not-found diagnostics, reserved-word/function-name protection | recursive substitution timing, trailing-space rules |
| `cat` | `builtin-cat-helper` | stdin, `-`, file operands | POSIX utility options are intentionally not a shell-conformance focus |
| `cd`, `pwd` | `builtin-cd-pwd`, `builtin-cd-logical-physical`, `builtin-cd-logical-dotdot`, `builtin-cd-usage-errors`, `builtin-pwd-logical-physical`, `builtin-pwd-usage-errors`, `vars-pwd` | logical PWD/OLDPWD, CDPATH, cd -, cd -L/-P, logical symlink dot-dot, pwd -L/-P, and cd/pwd usage diagnostics | deeper cd path diagnostics |
| `command` | `builtin-command`, `builtin-command-multiple-lookup`, `builtin-command-function-suppression`, `builtin-command-option-terminator`, `builtin-command-usage-errors` | `-p`, `-v`, `-V`, multiple lookup operands, `--`, function lookup suppression, option and lookup operand diagnostics | edge cases around special builtins, utilities, PATH errors |
| `env` | `builtin-env`, `builtin-env-option-terminator`, `builtin-env-usage-errors` | `-i`, `--`, assignments, command execution, printing, invalid option and command-not-found diagnostics | additional command propagation edge cases |
| `getopts` | `builtin-getopts`, `builtin-getopts-explicit-args`, `builtin-getopts-option-terminator`, `builtin-getopts-optind-reset`, `builtin-getopts-usage-errors` | clusters, required args, silent missing arg, explicit args, `--` termination, OPTIND reset, invalid optstring and variable-name diagnostics | remaining getopts edge cases |
| `printf` | `builtin-printf`, `builtin-printf-usage-errors`, printf subrows | escapes, `%b`/`%c`, format reuse, octal/hex, width/precision, missing format, invalid format/conversion, invalid numeric operand diagnostics | full POSIX format grammar and locale details |
| `read` | `builtin-read`, read subrows | backslash, `-r`, `--`, custom/empty IFS, last-variable remainder assignment, EOF status, unsupported option diagnostic | additional IFS edge cases, prompts if ever added |
| `test`, `[` | `builtin-test`, test subrows | file predicates including symlinks, terminal fds, mode bits, and special file types, string comparisons, integer comparisons, ordering, `!`/`-a`/`-o`/grouping grammar, invalid expression | remaining POSIX precedence and ambiguity edge cases |
| `umask` | `builtin-umask`, `builtin-umask-symbolic-output`, `builtin-umask-symbolic-operands`, `builtin-umask-usage-errors` | basic get/set, `-S` symbolic output, representative symbolic mask operands, invalid numeric/symbolic masks, unsupported options, excess operands | broader symbolic-mode edge cases |
| `wait` | `builtin-wait`, `builtin-wait-usage-errors` | tracked pid wait, invalid/unknown pid diagnostics | job specs, all-job semantics, stopped/interrupted jobs |

## Job-control builtins

| utility | manifest rows | current coverage | gaps |
| --- | --- | --- | --- |
| `jobs` | `builtin-jobs` | visible table, `-l`, `-p`, numeric, `%`, `%+`, `%%`, and `%-` job operands; current/previous markers; nonblocking status refresh | richer job specs and interactive notifications |
| `fg` | `job-fg-bg` | current, previous, and explicit tracked jobs wait and propagate status; stopped jobs get `SIGCONT` | full terminal handoff, richer job specs |
| `bg` | `job-fg-bg` | current, previous, and explicit tracked jobs report as backgrounded; stopped jobs get `SIGCONT` | richer job specs and notifications |

Follow-up tasks:

- full terminal mode restoration and interactive job notifications should be tracked separately from the baseline job-control builtins.

## Negative diagnostics coverage targets

The POSIX negative corpus covers representative builtin diagnostics for `test`, `read`, `wait`, POSIX special builtin usage failures, `getopts`, `printf`, and `umask`. Remaining builtin rows should add focused negative cases when implementing their listed option and operand gaps.

## Promotion guidance

Builtin rows should usually stay `baseline` while they are broad utility-level rows. Promote smaller `spec_clause` rows first, such as individual `test` predicate groups or `read -r` behavior, after unit, POSIX corpus, and negative corpus evidence exists. High-risk special-builtin consequence rows should not become `supported` until non-interactive exit behavior is modeled and covered.
