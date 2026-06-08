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

Validated for this audit refresh:

- `zig build test --summary all`: `149/149` passing
- `zig build corpus --summary all`: `102` cases, `408` comparisons across available comparison shells
- `zig build posix-corpus --summary all`: `119` expected-output POSIX cases
- `zig build cross-check --summary all`: passing for Linux/macOS/BSD compile checks

Recent notable capabilities:

- Real external command spawning with PATH lookup and foreground terminal handoff for inherited-stdio simple commands.
- Real OS fd plumbing for external redirections, pipelines, and mixed builtin/external pipelines.
- Real fd save/restore redirections for CLI inherited-stdio builtins, functions, subshells, brace groups, and arbitrary shell-visible fds.
- Redirection support for `<`, `>`, `>>`, `>|`, `<&`, `>&`, `n<&-`, `n>&-`, and `<>` baseline behavior.
- Here-doc baseline with ordered pending bodies, quoted delimiter behavior, tab stripping for `<<-`, expansion for unquoted bodies, and safe fd materialization.
- POSIX compound command execution baseline: `if`, `while`, `until`, `for`, `case`, functions, subshells, and brace groups.
- Structured CST nodes for key compound forms including `case_item` arms.
- POSIX pipeline negation with `!`.
- Baseline asynchronous external command execution with `&`, `$!`, background job records, and `wait` for pid operands.
- POSIX parameter expansion operators, pattern removal, command substitution via `$()` and legacy backquotes, arithmetic baseline, IFS-aware field splitting, pathname expansion baseline, quoted command substitution in double quotes, and true quoted `$@`/`$*` field behavior.
- Initial process environment import, command-prefix assignment semantics, POSIX special builtin assignment persistence, global positional parameters via `set --`, logical `PWD`/`OLDPWD`, and core special parameters `$?`, `$$`, `$!`, and `$0`.
- Baseline POSIX builtins now include `command`, `eval`, `exec`, `exit`, `readonly`, `shift`, `umask`, `wait`, `times`, `getopts`, `trap`, `alias`, and `unalias`.
- POSIX shell options baseline for `errexit`, `noglob`, `noclobber`, `nounset`, `verbose`, and `xtrace`.
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
- Async execution has a real external-command baseline and pid/job metadata, but compound/builtin async fallback is not a true subshell/background job yet.
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
- Exit status propagation and `$?` baseline.
- Logical `PWD`/`OLDPWD` tracking for `cd`/`pwd`.
- `$!` tracks the most recent real background external command pid.
- `wait` can wait for tracked background pids and returns their statuses.

### Partial / gaps

- `command -v` and command lookup controls are baseline-only.
- `exec` currently executes and exits through Rush's process model; it does not replace the Rush process image with `execve` yet.
- Special builtin error consequences are only partially modeled.
- PATH hashing/caching and POSIX command search edge cases are missing.
- Background job metadata is enough for `$!`/`wait`, but not for full job control.

### Missing / gaps

- Real `execve` replacement semantics for `exec` in CLI mode.
- Full POSIX special builtin error/exit behavior.
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
- `cat` baseline helper
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
- `wait` baseline with tracked pid operands
- `times` deterministic baseline
- `getopts` baseline
- `trap` baseline with `EXIT` trap execution
- `alias` / `unalias` baseline

### Partial / gaps

- `echo` has minimal behavior and intentionally avoids complex option/escape variations.
- `read` supports simple field assignment and `-r` acceptance but not full POSIX options/IFS/backslash behavior.
- `printf` supports common conversions/escapes, but not full POSIX format grammar.
- `test` baseline lacks many operators and edge cases.
- `set` has key POSIX options and positional handling, but not full option surface (`-a`, `-b`, `-m`, `-n`, etc.).
- `env` does not support arguments/options.
- `times` currently emits a deterministic baseline instead of real process usage.
- `command` supports baseline `-v`, but not the full POSIX option/lookup behavior.
- `exec` is not a true process replacement.
- `trap` does not yet install real signal handlers beyond `EXIT` execution.
- `alias`/`unalias` have baseline parser integration but not full POSIX recursive/timing edge cases.
- `cat` is a helper builtin for tests/pipelines, not a POSIX shell builtin requirement.

## 7. Shell options and modes

### Supported / baseline

- Shell option state exists.
- `pipefail` supported as a Bash compatibility option.
- Bash compatibility mode plumbing exists.
- Bash `[[ ... ]]` baseline.
- Bash arrays runtime model baseline.
- POSIX option baseline:
  - `set -- ...`
  - `set -f` / `set +f` noglob
  - `set -C` / `set +C` noclobber
  - `set -u` / `set +u` nounset
  - `set -e` / `set +e` errexit baseline
  - `set -x` / `set +x` xtrace baseline
  - `set -v` / `set +v` verbose baseline
  - `set -o name` / `set +o name` for supported options

### Partial / gaps

- Errexit is baseline-only and lacks many POSIX corner cases around compound commands, command substitutions, and AND-OR/pipeline contexts.
- Xtrace/verbose exact output ordering is baseline-only.
- Unsupported POSIX options remain:
  - `-a`
  - `-b`
  - `-m`
  - `-n`
  - others as applicable

## 8. Interactive behavior and job control

### Supported / baseline

- REPL skeleton.
- Syntax highlighting.
- Completion contexts.
- History/autosuggestion baseline.
- Persistent REPL executor state for functions, aliases, options, and environment.
- External simple commands inherit terminal stdio in CLI/REPL mode.
- Foreground process group handoff for simple inherited-stdio external commands.
- Rush survives SIGINT while idle/interactive; foreground children get default signal behavior.
- Baseline async external commands with `&`.
- `$!` and `wait pid` for tracked background external commands.

### Partial / gaps

- Process groups currently apply to simple external commands, not full pipelines/jobs.
- Background builtins/compound commands are not true concurrent subshell jobs yet.
- Job table is internal/minimal and not exposed through `jobs`.
- Stopped jobs and job status reporting are missing.
- Terminal modes are not saved/restored beyond foreground pgrp handoff.

### Missing / gaps

- Full job control:
  - process groups for foreground pipelines
  - real background subshell execution for compound/builtin async lists
  - job table UI
  - `jobs`, `fg`, `bg`
  - stopped process handling
  - terminal mode save/restore per job
- Signal handling model for pipelines and asynchronous lists.

## 9. Error handling and diagnostics

### Supported / baseline

- Parser diagnostics with source spans.
- Incomplete input detection for interactive use.
- Command-not-found returns `127` in simple commands and failed pipeline stage spawn.
- Missing pipeline stage spawn cleanup.
- Redirection failures for bad fd duplication and noclobber are shell-visible errors.
- Nounset produces a baseline unset-parameter diagnostic and exits non-interactive execution.

### Partial / gaps

- POSIX-specified shell error consequences are not modeled in detail.
- Expansion errors such as `${var:?word}` currently produce a baseline expansion failure rather than POSIX shell diagnostic text and exit behavior.
- Redirection errors and special builtin errors need stricter shell behavior.
- Some CLI inherited-stdio paths now write per-command output directly; capture-mode tests still intentionally model output through `CommandResult`.

## 10. Recommended next roadmap batches

### Batch A: Arithmetic and expansion correctness

1. Add shell variable lookup in arithmetic expansion.
2. Add arithmetic assignment and side effects on shell variables.
3. Add comparison, logical, bitwise, shift, ternary, and comma operators.
4. Harden unquoted `$@`/`$*` edge cases.
5. Expand pathname behavior for slash components and POSIX edge cases.
6. Add `~user` tilde lookup if desired.
7. Improve `${var:?word}` diagnostics and exit behavior.

### Batch B: Builtin depth

1. Implement real `execve` replacement semantics for CLI `exec cmd`.
2. Deepen `read` backslash/IFS behavior and option handling.
3. Deepen `printf` format grammar and diagnostics.
4. Deepen `test`/`[` operators and edge cases.
5. Deepen `command` options and lookup semantics.
6. Implement real `times` resource usage.
7. Deepen `set` unsupported POSIX options where useful.

### Batch C: Job control and signals

1. Add a visible job table and `jobs` builtin.
2. Add process groups for full foreground pipelines.
3. Run async compound/builtin lists in real subshell/background jobs.
4. Add `fg` and `bg` baselines.
5. Track stopped jobs and terminal mode save/restore.
6. Expand `trap` to real signal handling for common signals.

### Batch D: Parser/CST precision

1. Improve alias substitution timing and reserved-word interaction.
2. Add strict POSIX grammar diagnostics mode separate from recovery/tooling mode.
3. More complete here-doc parser/token integration.
4. Structure function body lowering instead of reparsing source slices.
5. Harden case grammar edge cases.

### Batch E: Redirection and execution edge cases

1. Extend real fd semantics to more capture/test paths where practical.
2. Audit obscure redirection ordering and special-builtin failure consequences.
3. Improve here-doc materialization/parser integration further.
4. Audit PATH search, executable permissions, and command hashing/caching behavior.

## Suggested immediate priorities

For the next milestone, the best sequence is:

1. Arithmetic variable lookup and broader arithmetic operators.
2. Real `exec` replacement semantics in CLI mode.
3. Builtin depth for `read`, `printf`, `test`, and `command`.
4. Job table and `jobs` builtin, building on the existing `$!`/`wait` metadata.
5. Parser precision around alias substitution, strict diagnostics, and here-doc integration.
