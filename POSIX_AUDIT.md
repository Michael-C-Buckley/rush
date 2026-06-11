# POSIX Shell Audit

Date: 2026-06-08

This audit compares Rush's current implementation against the POSIX Shell Command Language at a practical feature level. It is a gap analysis for implementation planning, not a normative copy of the specification.

Status legend:

- **Supported**: implemented with unit tests and/or corpus coverage.
- **Baseline**: useful implementation exists, but important POSIX edge cases remain.
- **Partial**: recognizable implementation exists, but significant semantics are missing.
- **Missing**: not implemented or only placeholder behavior.
- **Out of scope for now**: POSIX-adjacent or optional interactive/job-control behavior not needed for the current milestone.

## Current snapshot

The machine-readable checklist in `test/compliance/posix-shell.tsv` and the generated `zig build compliance --summary all` report are the source of truth for current scoring. The percentages are planning heuristics, not formal POSIX certification.

Validated for this audit refresh:

- `zig build compliance --summary all`: passing
- `zig build test --summary all`: `251/251` passing
- `zig build corpus --summary all`: `122` cases, `488` comparisons across available comparison shells
- `zig build posix-corpus --summary all`: `153` expected-output POSIX cases
- `zig build posix-negative-corpus --summary all`: `15` expected-error POSIX cases
- `zig build cross-check --summary all`: passing for Linux/macOS/BSD compile checks

Current compliance report snapshot:

- tracked items: `110`
- scored POSIX items: `108`
- supported: `15`
- baseline: `78`
- partial: `11`
- missing: `4`
- out of scope: `2`
- strict supported only: `13.9%`
- practical supported+baseline: `86.1%`
- weighted progress: `67.5%`

Recent notable capabilities:

- Real external command spawning with PATH lookup and foreground terminal handoff for inherited-stdio simple commands.
- Real OS fd plumbing for external redirections, pipelines, and mixed builtin/external pipelines.
- Real fd save/restore redirections for CLI inherited-stdio builtins, functions, subshells, brace groups, and arbitrary shell-visible fds.
- Redirection support for `<`, `>`, `>>`, `>|`, `<&`, `>&`, `n<&-`, `n>&-`, and `<>` baseline behavior.
- Here-doc baseline with ordered pending bodies, quoted delimiter behavior, tab stripping for `<<-`, expansion for unquoted bodies, and safe fd materialization.
- POSIX compound command execution baseline: `if`, `while`, `until`, `for`, `case`, functions, subshells, and brace groups.
- Structured CST nodes for key compound forms including `case_item` arms.
- POSIX pipeline negation with `!`.
- Baseline asynchronous external, builtin, and compound command execution with `&`, `$!`, visible background job records, `jobs`, `fg`, `bg`, and `wait` for pid operands.
- POSIX parameter expansion operators, pattern removal, `${parameter:?word}` diagnostics, command substitution via `$()` and legacy backquotes, arithmetic baseline, IFS-aware field splitting, pathname expansion baseline, quoted command substitution in double quotes, and quoted/unquoted `$@`/`$*` baseline field behavior.
- Initial process environment import, command-prefix assignment semantics, POSIX special builtin assignment persistence, global positional parameters via `set --`, logical `PWD`/`OLDPWD`, and core special parameters `$?`, `$$`, `$!`, and `$0`.
- Baseline POSIX builtins now include `command`, `eval`, `exec`, `exit`, `readonly`, `shift`, `umask`, `wait`, `times`, `getopts`, `trap`, `alias`, `unalias`, `jobs`, `fg`, `bg`, and `kill`.
- POSIX shell options baseline for `allexport`, `errexit`, `noglob`, `noclobber`, `noexec`, `nounset`, `verbose`, and `xtrace`, plus reusable supported-option listing.
- Prompt prototype support scoped so prompt DSL commands are only available during prompt rendering.

## 1. Lexical conventions and token recognition

### Supported / baseline

- Basic tokenization of words, whitespace, comments, and newlines.
- Basic operators:
  - `|`
  - `&&`
  - `||`
  - `;`
  - `;;`
  - `&`
  - `(` `)`
  - redirection operators: `<`, `>`, `<<`, `<<-`, `>>`, `<&`, `>&`, `<>`, `>|`
- Quote recognition in expansion:
  - single quotes
  - double quotes
  - backslash escapes
- Nested command substitution CST recognition for `$()`.
- Legacy backquote command substitution recognition in the lexer/expansion pipeline.
- Alias expansion is integrated ahead of parser lowering for future input/script slices.

### Partial / gaps

- Reserved words are recognized mostly by parser context/string matching rather than a fully POSIX grammar phase.
- Newline/list handling works for common constructs, but the parser remains permissive and recovery-oriented rather than a strict POSIX grammar.
- Alias substitution is baseline-only:
  - not a complete token-recognition state machine
  - not fully recursive in all POSIX edge cases
  - reserved-word interaction needs more coverage
- Double-quote and backslash behavior has broad baseline coverage, but more edge cases remain around recursive parsing contexts.
- Escaped-newline handling exists in places but is not a complete token-recognition state machine.

### Missing / gaps

- Full POSIX token recognition state machine:
  - recursive quote tracking across all grammar contexts
  - here-doc token/body collection exactly at parser level
  - exact alias substitution timing and reserved-word effects
- Strict reserved-word grammar disambiguation.

## 2. Grammar and command forms

### Supported / baseline

- Simple commands with assignments, argv words, and redirections.
- Pipelines, including POSIX `! pipeline` negation.
- AND-OR lists via `&&` and `||`.
- Sequential lists via `;` and newlines.
- Asynchronous command/list terminator baseline via `&`.
- POSIX compound commands:
  - `if ... then ... else ... fi`
  - `while ... do ... done`
  - `until ... do ... done`
  - `for name in ... do ... done`
  - `case word in ... esac`
  - subshell `( list )`
  - brace group `{ list; }`
- POSIX-style function definitions: `name() { ...; }`.
- Parser CST includes nested list bodies for key compound command regions.
- Parser CST includes structured `case_item` nodes for case arms.

### Partial / gaps

- `case` execution supports basic patterns and structured CST arms, but full POSIX case grammar edge cases remain:
  - multiple pattern separators
  - empty arms
  - alternate terminators in future Bash modes
- `for` supports POSIX word lists, but not Bash-style arithmetic for loops.
- Function definitions use body source slicing and reparse at call time; semantics work for baseline tests but are not yet a fully lowered function body IR.
- Async execution has real external-command baseline, forked builtin/compound jobs where IO/fork context is available, and pid/job metadata.
- Strict syntax errors where POSIX requires them are not fully enforced; Rush still favors recovery/incomplete-input behavior for tooling.

## 3. Expansions

POSIX expansion order broadly includes tilde expansion, parameter expansion, command substitution, arithmetic expansion, field splitting, pathname expansion, and quote removal, with context-dependent exceptions.

### Supported / baseline

- Tilde expansion for `~` and `~/...` using `HOME`.
- Parameter expansion baseline:
  - `$name`
  - `${name}`
  - global and function positional parameters `$1`, `$#`, `$@`, `$*`
  - quoted `$@` multi-field behavior
  - quoted `$*` joining with first `IFS` character
  - core special parameters `$?`, `$$`, `$!`, `$0`
  - `${var:-word}`
  - `${var-word}`
  - `${var:=word}`
  - `${var=word}`
  - `${var:+word}`
  - `${var+word}`
  - `${var:?word}` baseline error
  - `${#var}`
  - `${var%word}`
  - `${var%%word}`
  - `${var#word}`
  - `${var##word}`
- Arithmetic expansion baseline for integer expressions:
  - `+`, `-`, `*`, `/`, `%`, parentheses, unary `+`/`-`
- Command substitution with `$()` including nested parsing and executor-backed execution.
- Legacy backquote command substitution baseline.
- Command substitution inside double quotes, preserving the quoted field.
- Field splitting honors `IFS`, including empty IFS and non-whitespace delimiters.
- Pathname expansion using current directory glob support for `*`, `?`, bracket classes.
- Quote removal baseline with POSIX double-quote backslash handling for common cases.
- Here-doc expansion for unquoted delimiters; quoted delimiters suppress expansion.

### Partial / gaps

- Expansion order is modeled but still simplified around quote contexts and nested constructs.
- Parameter expansion `word` portions are recursively expanded, but error diagnostics and shell-exit consequences are minimal.
- Arithmetic expansion does not resolve shell variables inside arithmetic expressions.
- Arithmetic expansion lacks assignment, logical, comparison, bitwise, and comma operators.
- Pathname expansion lacks full POSIX details such as slash-component behavior and locale/collation details.
- Tilde expansion does not support `~user`.
- Unquoted `$@`/`$*` behavior is acceptable for common cases but still needs more spec-derived edge-case coverage.

### Missing / gaps

- Arithmetic variable lookup and broader arithmetic grammar.
- Arithmetic assignment semantics and side effects on shell variables.
- Full quote-aware expansion and field generation in all nested contexts.
- Full pathname expansion semantics.
- `~user` lookup.
- POSIX-accurate diagnostics and exit behavior for expansion errors such as `${var:?word}`.

## 4. Redirection

### Supported / baseline

- Input redirection `<`.
- Output redirection `>`.
- Append redirection `>>` using real `O_APPEND`.
- Noclobber `set -C` with `>|` override.
- Stderr and arbitrary fd output redirections such as `2>` and `3>`.
- Descriptor duplication with `<&` and `>&`, including bad-fd handling for shell-visible fds.
- Close redirections `n<&-` and `n>&-`.
- Read-write redirection `<>` including arbitrary fd forms such as `3<>file`.
- Pipeline-stage redirections overriding pipe endpoints.
- Here-docs:
  - `<<`
  - `<<-`
  - ordered pending bodies
  - quoted delimiter disables expansion
  - unquoted body expansion baseline
  - safe fd materialization
- External commands use real file descriptors.
- CLI inherited-stdio builtins, functions, subshells, and brace groups use temporary OS fd mutation and restore for supported fd forms.
- Shell-visible fd tracking prevents internal fds from being accidentally exposed as shell fds.

### Partial / gaps

- Capture-mode tests still use captured-result modeling in some paths instead of true inherited process fds.
- More obscure redirection ordering/error interactions remain to be audited.
- Here-doc materialization is fd-backed but full parser-level here-doc token/body integration is still simplified.

## 5. Command search and execution environment

### Supported / baseline

- Builtin dispatch.
- Function dispatch.
- External command spawn with PATH search.
- Parent process environment import into shell state.
- Assignment-only commands mutate shell environment.
- Command-prefix assignment semantics:
  - temporary for regular builtins/functions/external commands
  - persistent for assignment-only and POSIX special builtins
  - included in external process environments
- `export`, `unset`, `env` baseline.
- Subshell executes with copied executor state.
- Brace group executes in current executor.
- Functions have call frames and positional parameters.
- Global positional parameters via `set --`.
- POSIX special builtin classification baseline.
- POSIX special builtin error consequences are modeled for the audited XCU 2.8.1/2.15 cases: expansion/redirection failures, invalid options or operands where applicable, and utility-semantic failures stop non-interactive execution across all 15 special builtins.
- Exit status propagation and `$?` baseline.
- Logical `PWD`/`OLDPWD` tracking for `cd`/`pwd`.
- `$!` tracks the most recent real background external command pid.
- `wait` can wait for tracked background pids and job IDs, returns operand statuses, and returns zero after waiting for all known jobs when invoked without operands.

### Partial / gaps

- `command -v` and command lookup controls are baseline-only.
- `exec` currently executes and exits through Rush's process model; it does not replace the Rush process image with `execve` yet.
- PATH hashing/caching and POSIX command search edge cases are missing.
- Background job metadata is enough for `$!`/`wait`, but not for full job control.

### Missing / gaps

- Real `execve` replacement semantics for `exec` in CLI mode.
- Additional implementation-specific `exec` replacement and command-search edge cases.
- Full signal environment semantics.
- Command search cache/hash behavior if desired later.

## 6. Builtins

### Supported / baseline

Implemented or partially implemented:

- `:`
- `.` / `source`
- `break`
- `continue`
- `cd`
- `pwd`
- `return`
- `echo`
- `false`
- `true`
- `export`
- `unset`
- `env`
- `set` baseline for shell options and positional parameters
- `test` / `[` baseline
- `read` baseline
- `printf` baseline
- `command` baseline
- `eval` baseline
- `exec` baseline
- `exit` baseline
- `readonly` baseline
- `shift` baseline
- `umask` baseline
- `wait` builtin with tracked pid/job operands, no-operand all-job semantics, and last-operand status
- `times` deterministic baseline
- `getopts` baseline
- `trap` baseline with `EXIT` trap execution
- `alias` / `unalias` baseline

### Partial / gaps

- `echo` has minimal behavior and intentionally avoids complex option/escape variations.
- `read` supports simple field assignment and `-r` acceptance but not full POSIX options/IFS/backslash behavior.
- `printf` supports common conversions/escapes, but not full POSIX format grammar.
- `test` baseline lacks many operators and edge cases.
- `set` has the POSIX non-interactive short option baseline, positional handling, interactive `ignoreeof`, interactive `notify` polling for background job status while the editor is active, interactive `monitor` process groups for tracked async jobs, and explicit no-effect compatibility handling for obsolescent `-h`/`nolog`, but not the full optional interactive/User Portability surface (`vi` editing mode and complete job-control terminal semantics).
- `env` does not support arguments/options.
- `times` currently emits a deterministic baseline instead of real process usage.
- `command` supports baseline `-v`, but not the full POSIX option/lookup behavior.
- `exec` is not a true process replacement.
- `trap` has supported real-signal dispatch for the tracked common catchable signals, including ignored-at-entry non-interactive behavior, caught-trap reset in subshells and command substitutions, signal trap status preservation, EXIT trap ordering for signal and `errexit` exits, wait interruption by trapped signals, and prompt editor wake/redraw for process-directed trapped signals.
- `alias`/`unalias` have baseline parser integration but not full POSIX recursive/timing edge cases.

## 7. Shell options and modes

### Supported / baseline

- Shell option state exists.
- `pipefail` supported as a Bash compatibility option.
- Bash compatibility mode plumbing exists.
- Bash `[[ ... ]]` baseline.
- Bash arrays runtime model baseline.
- POSIX option baseline:
  - `set -- ...`
  - `set -a` / `set +a` allexport
  - `set -f` / `set +f` noglob
  - `set -C` / `set +C` noclobber
  - `set -u` / `set +u` nounset
  - `set -e` / `set +e` errexit baseline
  - `set -n` / `set -o noexec` noexec syntax-check behavior
  - `set -x` / `set +x` xtrace baseline
  - `set -v` / `set +v` verbose baseline
  - `$-` reflects representative current short shell option flags
  - option parsing followed by positional operands, including `--`, `-`, and `+` terminator behavior
  - `set -o name` / `set +o name` for supported options
  - `set -o` option state listing in Rush's stable human-readable format
  - `set +o` reusable option-state command listing for supported options
  - `set -o ignoreeof` / `set +o ignoreeof` controls whether interactive EOF asks for explicit `exit`
  - `set -m` / `set -o monitor` reflects in option state and enables separate process groups for tracked async jobs in interactive and non-interactive shells; without monitor mode, non-interactive async jobs remain in the shell process group.
  - `set -h` / `set +h` and `set -o nolog` / `set +o nolog` are accepted as no-effect obsolescent compatibility spellings; they do not change command lookup, history, `$-`, or option listings.

### Partial / gaps

- Errexit is baseline-only and lacks many POSIX corner cases around compound commands, command substitutions, and AND-OR/pipeline contexts.
- Xtrace/verbose exact output ordering is baseline-only.
- Unsupported POSIX option behavior remains:
  - `set -o vi` command-line editing mode

## 8. Interactive behavior and job control

### Supported / baseline

- REPL skeleton.
- Syntax highlighting.
- Completion contexts.
- History/autosuggestion baseline.
- Persistent REPL executor state for functions, aliases, options, and environment.
- External simple commands inherit terminal stdio in CLI/REPL mode.
- Foreground process group handoff for simple inherited-stdio external commands.
- Interactive SIGINT/interrupt handling discards the current editor line and returns to a fresh prompt without changing `$?`; an active `trap ... INT` runs instead of the plain discard path. Process-directed trapped signals wake the editor through the trap self-pipe, run the pending trap, and redraw the current input. The interactive shell catches INT/QUIT/TERM for itself, while foreground job child/wrapper processes reset those dispositions to defaults before running job-owned code.
- Baseline async external, builtin, and compound commands with `&`.
- `$!` and `wait` for tracked background commands, including brace groups, subshells, loops, and pipelines started asynchronously.
- Asynchronous commands use `/dev/null` as default stdin when job control is disabled, without consuming the invoking shell's stdin.
- Forked asynchronous compound jobs inherit shell option state, reset caught traps for the subshell environment, keep nested subshell async jobs out of the parent job table, and report redirection diagnostics while remaining waitable.
- Visible job table through `jobs`, including POSIX-spaced normal and `-l` output, `-p`, Running/Done/Done(code)/Stopped signal state strings, numeric/% job operands, empty subshell and command-substitution tables, and removal of completed jobs after their termination status is reported.
- Monitor-enabled `fg` waits for current or explicit tracked jobs, returns the foreground job status, writes the command line, and removes completed foreground jobs from the waitable job table.
- Monitor-enabled `bg` reports current, explicit, and multiple tracked jobs with the POSIX `[%d] %s` format.
- `kill` is available as a shell builtin so POSIX job ID operands can target Rush's job table, with default `TERM`, `-s signal`, `-signal`, `-0`, pid operands, and process-group signaling for tracked jobs when available.
- Foreground process group handling for inherited-stdio external-only pipelines.
- Foreground inherited-stdio mixed pipelines fork through a job-owned wrapper process group before terminal handoff, so builtin/function stages are no longer run by the parent shell while the job owns the terminal.
- Stopped foreground inherited-stdio mixed pipelines are recorded in the job table, restore the shell foreground process group, and can be resumed through `fg` after SIGTSTP/SIGTTIN/SIGTTOU stops in the job-owned wrapper process group.
- Monitor mode (`set -m`) puts tracked async external and forked compound/mixed-pipeline jobs in their own process groups, keeps background jobs from taking foreground terminal ownership, lets `fg` hand the terminal to that saved process group when available, and gates `fg`/`bg` job-control behavior.
- `wait` with no operands waits all known jobs and returns zero unless interrupted by a trapped signal; pid/job operands return the last operand status, with invalid/unknown operands following Rush's regular builtin failure status 127 diagnostic policy.
- `jobs`, `fg`, `bg`, `wait`, and `kill` resolve POSIX job IDs for current (`%%`/`%+`), previous (`%-`), numeric (`%n`), prefix (`%string`), and substring (`%?string`) forms where the match is unambiguous.
- Stopped-job lifecycle coverage includes stopped status refresh and prompt notifications, 128+signal status for stopped foreground jobs, dash-compatible `wait` behavior that remains blocked while a stopped job is not continued, stopped→done refresh/notification when a stopped job is killed, saved terminal mode restore on `fg`, and the dash-compatible first `exit` warning while stopped jobs remain.

### Partial / gaps

- Signal handling for pipelines and asynchronous lists remains conservative.

### Missing / gaps

- Full job control:
  - remaining signal-handling edge cases across pipelines and asynchronous lists

## 9. Error handling and diagnostics

### Supported / baseline

- Parser diagnostics with source spans.
- Incomplete input detection for interactive use.
- Command-not-found returns `127` in simple commands and failed pipeline stage spawn.
- Missing pipeline stage spawn cleanup.
- Redirection failures for bad fd duplication and noclobber are shell-visible errors.
- Nounset produces a baseline unset-parameter diagnostic and exits non-interactive execution.
- `${parameter:?word}` expands the diagnostic word, reports the parameter name, and exits non-interactive execution.
- Special builtin expansion, redirection, invalid option/operand, and utility-semantic failures now stop non-interactive execution for the audited POSIX special-builtin set.
- Negative POSIX corpus covers syntax, expansion, redirection, and builtin diagnostic cases.

### Partial / gaps

- Redirection error consequences outside the special-builtin baseline need stricter context modeling.
- Some CLI inherited-stdio paths now write per-command output directly; capture-mode tests still intentionally model output through `CommandResult`.

## 10. Recommended next roadmap batches

The detailed backlog lives in Tend and the machine-readable status lives in `test/compliance/posix-shell.tsv`. Current non-completion implementation priorities are:

### Batch A: Parser/CST precision

1. `#158` Harden POSIX case grammar edge cases, especially empty arms and pattern-list forms.
2. `#157` Lower function bodies into structured IR instead of reparsing source slices.
3. Continue strict diagnostics only where explicitly requested by `--posix-strict` so editor recovery remains useful.

### Batch B: Pathname and expansion edge cases

1. `#159` Deepen pathname expansion POSIX edge cases, especially slash components, dotfiles, and unmatched patterns.
2. Add narrower spec-clause rows if embedded or empty positional-parameter behavior needs separate scoring beyond `#160`.
3. Keep diagnostics and shell-error consequences in the negative corpus when they are not differential-safe.

### Batch C: Compliance evidence growth

1. `#169` Import dash-derived POSIX language smoke cases.
2. `#170` Import BusyBox ash-inspired builtin and redirection cases.
3. `#171` Add spec-clause examples for current high-risk POSIX gaps.
4. Keep `POSIX_AUDIT.md` as prose context and avoid duplicating generated compliance totals beyond snapshot refreshes.

### Batch D: Job-control and error-consequence depth

1. Deepen pipeline/asynchronous-list signal-handling edge cases beyond the supported job-control utility rows.
2. Deepen non-special redirection and expansion consequence edge cases that remain partial.

Keep adding POSIX corpus, negative corpus, and manifest evidence alongside each behavior change.
