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
| `.` | `builtin-dot`, `builtin-dot-current-env`, `builtin-dot-usage-errors` | `dash-smoke-dot-current-env` plus missing/nonexistent file diagnostics and unit coverage | PATH search, non-readable file behavior |
| `break`, `continue` | `builtin-break-continue`, `builtin-loop-control-outside-loop`, `builtin-loop-control-usage-errors` | `builtin-loop-control`, outside-loop and operand diagnostic negative corpus | nested levels |
| `eval` | `builtin-eval` | `builtin-eval`, `builtin-eval-special-assignment` | parse/expansion failure consequences |
| `exec` | `builtin-exec` | `builtin-exec`, `builtin-exec-assignment-env`, `builtin-exec-replaces-process` | redirection-only exec, failure status details, no-return contexts |
| `exit` | `builtin-exit`, `builtin-exit-usage-errors` | `builtin-exit`, `builtin-exit-invalid-operand`, `builtin-exit-too-many` | additional status/diagnostic corpus |
| `export` | `builtin-export-unset`, `builtin-export-readonly-p`, `builtin-variable-usage-errors` | `builtin-export-env`, `export -p`, invalid-name, readonly-assignment, unsupported-option, and `-p` usage diagnostics | full reusable listing quoting details |
| `readonly` | `vars-readonly`, `builtin-export-readonly-p`, `builtin-variable-usage-errors` | `builtin-readonly`, `readonly -p`, invalid-name, readonly-assignment, unsupported-option, and `-p` usage diagnostics | full reusable listing quoting details |
| `return` | `builtin-return-usage-errors` plus function tests | `builtin-return-status`, `builtin-return-outside-function`, `builtin-return-invalid-operand`, `builtin-return-too-many`, unit coverage | additional status/diagnostic corpus |
| `set` | `option-set`, `option-set-usage-errors`, option rows | shell option and positional parameter corpus, invalid option diagnostics | many POSIX flags, broader `--` behavior |
| `shift` | `builtin-shift-too-far`, `builtin-shift-usage-errors`, builtin row through tests | `builtin-shift`, `builtin-shift-too-far`, `builtin-shift-invalid-operand`, `builtin-shift-too-many` | additional status/diagnostic corpus |
| `times` | `builtin-times` | `builtin-times` | portability/runtime precision is baseline only |
| `trap` | `builtin-trap`, `signal-trap-real` | listing, clear, EXIT, INT signal corpus | signal semantics, ignored signals, invalid names, inheritance |
| `unset` | `builtin-export-unset`, `builtin-unset-variable-function`, `builtin-variable-usage-errors` | unset -v, unset -f, invalid-name, readonly-variable, and unsupported-option coverage | remaining function/variable edge cases |

High-risk rows:

- `errors-special-builtin`
- `errors-special-builtin-redirection`
- `errors-special-builtin-expansion`
- `builtin-special`

Follow-up task: `#156 Model POSIX special builtin error consequences`.

## Regular POSIX utilities implemented as builtins

| utility | manifest rows | current coverage | gaps |
| --- | --- | --- | --- |
| `alias`, `unalias` | `builtin-alias`, `builtin-alias-usage-errors`, alias lexing rows | list, remove, invalid-name/not-found diagnostics, reserved-word/function-name protection | recursive substitution timing, trailing-space rules |
| `cat` | `builtin-cat-helper` | stdin, `-`, file operands | POSIX utility options are intentionally not a shell-conformance focus |
| `cd`, `pwd` | `builtin-cd-pwd`, `builtin-cd-logical-physical`, `builtin-cd-usage-errors`, `builtin-pwd-logical-physical`, `builtin-pwd-usage-errors`, `vars-pwd` | logical PWD/OLDPWD, CDPATH, cd -, cd -L/-P, pwd -L/-P, and cd/pwd usage diagnostics | deeper symlink normalization and cd path diagnostics |
| `command` | `builtin-command`, `builtin-command-usage-errors` | `-p`, `-v`, `-V`, lookup suppression, option and lookup operand diagnostics | edge cases around special builtins, functions, utilities, PATH errors |
| `env` | `builtin-env`, `builtin-env-usage-errors` | `-i`, assignments, command execution, printing, invalid option and command-not-found diagnostics | additional command propagation edge cases |
| `getopts` | `builtin-getopts`, `builtin-getopts-usage-errors` | clusters, required args, silent missing arg, invalid optstring and variable-name diagnostics | OPTIND edge cases, explicit args edge cases |
| `printf` | `builtin-printf`, `builtin-printf-usage-errors`, printf subrows | escapes, format reuse, octal/hex, width/precision, missing format, invalid format/conversion, invalid numeric operand diagnostics | full format grammar |
| `read` | `builtin-read`, read subrows | backslash, `-r`, custom IFS, last-variable remainder assignment, unsupported option diagnostic | EOF status, additional IFS edge cases, prompts if ever added |
| `test`, `[` | `builtin-test`, test subrows | file predicates including symlinks, terminal fds, and special file types, string comparisons, integer comparisons, ordering, invalid expression | complete POSIX expression grammar, precedence edge cases |
| `umask` | `builtin-umask`, `builtin-umask-symbolic-output`, `builtin-umask-usage-errors` | basic get/set, `-S` symbolic output, invalid numeric/symbolic masks, unsupported options, excess operands | symbolic mask operands |
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
