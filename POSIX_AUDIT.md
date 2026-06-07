# POSIX Shell Audit

Date: 2026-06-07

This audit compares Rush's current implementation against the POSIX Shell Command Language at a practical feature level. It is not a legal/normative copy of the specification; it is a gap analysis for implementation planning.

Status legend:

- **Supported**: implemented with tests or exercised by corpus.
- **Partial**: recognizable implementation exists, but important POSIX semantics are missing.
- **Missing**: not implemented or only placeholder behavior.
- **Out of scope for now**: POSIX-adjacent or optional interactive/job-control behavior not needed for the current milestone.

## Current snapshot

Validated before this audit refresh:

- `zig build test --summary all`: `136/136` passing
- `zig build corpus --summary all`: `78` cases, `312` comparisons across available comparison shells
- `zig build posix-corpus --summary all`: `80` expected-output POSIX cases
- `zig build cross-check --summary all`: passing for Linux/macOS/BSD compile checks

Recent notable capabilities:

- Real external command spawning.
- Real file-descriptor plumbing for external redirections and pipelines.
- Real fd save/restore redirections for CLI inherited-stdio builtins, functions, subshells, and brace groups.
- Mixed builtin/external pipelines using OS pipes and worker threads.
- Foreground terminal handoff for inherited-stdio external commands.
- Interactive SIGINT survival baseline.
- POSIX compound command execution baseline: `if`, `while`, `until`, `for`, `case`, functions, subshells, brace groups.
- Here-doc baseline with ordered pending bodies, quoted delimiter behavior, tab stripping for `<<-`, expansion for unquoted bodies, and unique temporary materialization.
- POSIX parameter expansion operators, pattern removal, command substitution via `$()` and legacy backquotes, arithmetic baseline, IFS-aware field splitting, pathname expansion baseline, and true quoted `$@`/`$*` function positional field behavior.
- Initial process environment import, command-prefix assignment semantics, POSIX special builtin assignment persistence, and core special parameters `$?`, `$$`, `$!`, `$0` baseline.
- Baseline POSIX builtin set expanded with `command`, `eval`, `exec`, `exit`, `readonly`, `shift`, `umask`, `wait`, and `times`.

## 1. Lexical conventions and token recognition

### Supported

- Basic tokenization of words, whitespace, comments, newlines.
- Basic operators:
  - `|`
  - `&&`
  - `||`
  - `;`
  - `;;`
  - `&`
  - `(` `)`
  - redirection operators: `<`, `>`, `<<`, `<<-`, `>>`, `<&`, `>&`, `<>`, `>|`
- Basic quote recognition in expansion:
  - single quotes
  - double quotes
  - backslash escapes
- Nested command substitution CST recognition for `$()`.
- Legacy backquote command substitution recognition in the lexer/expansion pipeline.

### Partial

- Reserved words are recognized mostly by parser context/string matching rather than a fully POSIX grammar phase.
- Newline/list handling works for common constructs, but the parser remains permissive and recovery-oriented rather than a strict POSIX grammar.
- Double-quote and backslash behavior has POSIX baseline coverage, but more edge cases remain around recursive parsing contexts.
- Escaped-newline handling exists in places but is not a complete token-recognition state machine.

### Missing / gaps

- Full POSIX token recognition state machine:
  - recursive quote tracking across all grammar contexts
  - here-doc token/body collection exactly at parser level
  - alias substitution timing
- Complete reserved-word grammar disambiguation.
- Alias substitution and its impact on token recognition/reserved words.

## 2. Grammar and command forms

### Supported

- Simple commands with assignments, argv words, and redirections.
- Pipelines.
- AND-OR lists via `&&` and `||`.
- Sequential lists via `;` and newlines.
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

### Partial

- `case` execution supports basic patterns, but case CST arms are still represented as a raw list-ish region rather than structured case item nodes with pattern/body children.
- `for` supports POSIX word lists, but not Bash-style arithmetic for loops.
- Function definitions use body source slicing and reparse at call time; semantics work for baseline tests but are not yet a fully lowered function body IR.
- Background execution with `&` is tokenized/list-separated but not semantically implemented as async jobs.
- Pipeline negation with `!` is not implemented.

### Missing / gaps

- Full POSIX grammar for:
  - `case_item` structure, multiple patterns, terminators, empty arms
  - complete `compound_list` newline/separator edge cases
  - `function_body` redirection/body structure
  - `! pipeline`
  - asynchronous lists (`cmd &`) execution semantics
- Strict syntax errors where POSIX requires them; Rush currently favors recovery/incomplete-input behavior for tooling.

## 3. Expansions

POSIX expansion order broadly includes tilde expansion, parameter expansion, command substitution, arithmetic expansion, field splitting, pathname expansion, and quote removal, with context-dependent exceptions.

### Supported

- Tilde expansion for `~` and `~/...` using `HOME`.
- Parameter expansion baseline:
  - `$name`
  - `${name}`
  - function positional parameters `$1`, `$#`, `$@`, `$*`
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
- Field splitting honors `IFS`, including empty IFS and non-whitespace delimiters.
- Pathname expansion using current directory glob support for `*`, `?`, bracket classes.
- Quote removal baseline with POSIX double-quote backslash handling for common cases.
- Here-doc expansion for unquoted delimiters; quoted delimiters suppress expansion.

### Partial

- Expansion order is modeled but still simplified around quote contexts and nested constructs.
- Parameter expansion `word` portions are recursively expanded, but error diagnostics and shell-exit consequences are minimal.
- Arithmetic expansion does not resolve shell variables inside arithmetic expressions.
- Arithmetic expansion lacks assignment, logical, comparison, bitwise, and comma operators.
- Pathname expansion lacks full POSIX details such as slash-component behavior and locale/collation details.
- Tilde expansion does not support `~user`.
- Unquoted `$@`/`$*` behavior is acceptable for common cases but still needs more spec-derived edge-case coverage.

### Missing / gaps

- Arithmetic variable lookup and broader arithmetic grammar.
- Full quote-aware expansion and field generation in all nested contexts.
- Full pathname expansion semantics.
- `~user` lookup.
- POSIX-accurate diagnostics and exit behavior for expansion errors such as `${var:?word}`.

## 4. Redirection

### Supported

- Input redirection `<`.
- Output redirection `>`.
- Append redirection `>>` using real `O_APPEND`.
- Stderr redirection `2>`.
- Descriptor duplication baseline for common `>&` cases.
- Pipeline-stage redirections overriding pipe endpoints.
- Here-docs:
  - `<<`
  - `<<-`
  - ordered pending bodies
  - quoted delimiter disables expansion
  - unquoted body expansion baseline
  - unique temp-file materialization
- External commands use real file descriptors.
- CLI inherited-stdio builtins, functions, subshells, and brace groups use temporary OS fd mutation and restore for supported fd forms.

### Partial

- Descriptor duplication operators `<&` and `>&` are real in inherited-stdio mode for fd `0`, `1`, and `2`, but capture-mode tests still use captured-result modeling.
- Arbitrary fd numbers beyond `0`, `1`, and `2` are not complete.
- `<>` and `>|` are tokenized but not fully implemented.
- Close redirections (`n<&-`, `n>&-`) are not implemented.

### Missing / gaps

- Arbitrary fd redirections and save/restore.
- Close redirections (`n<&-`, `n>&-`).
- `<>` read-write redirection.
- `>|` noclobber interaction once `set -C` exists.
- Safer anonymous-fd/pipe here-doc materialization would be preferable to unique temp files long-term.

## 5. Command search and execution environment

### Supported

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
- POSIX special builtin classification baseline.
- Exit status propagation and `$?` baseline.

### Partial

- `command -v` and command lookup controls are baseline-only.
- `exec` currently executes and exits through Rush's process model; it does not replace the Rush process image with `execve` yet.
- `$!` has a placeholder/baseline value because background jobs are not implemented.
- Special builtin error consequences are only partially modeled.
- PATH hashing/caching and POSIX command search edge cases are missing.

### Missing / gaps

- Real `execve` replacement semantics for `exec` in CLI mode.
- Full POSIX special builtin error/exit behavior.
- `trap` and signal environment semantics.
- Background job environment and `$!` correctness.
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
- `set` baseline for shell option plumbing and `pipefail`
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
- `wait` baseline without jobs
- `times` baseline

### Partial

- `echo` has minimal behavior and intentionally avoids complex option/escape variations.
- `read` supports simple field assignment and `-r` acceptance but not full POSIX options/IFS/backslash behavior.
- `printf` supports common conversions/escapes, but not full POSIX format grammar.
- `test` baseline lacks many operators and edge cases.
- `set` is mostly shell option plumbing, not full POSIX option or positional-parameter behavior.
- `env` does not support arguments/options.
- `wait` has no job/process operand semantics yet.
- `times` currently emits a deterministic baseline instead of real process usage.
- `cat` is a helper builtin for tests/pipelines, not a POSIX shell builtin requirement.

### Missing POSIX special/regular builtins

High-priority missing:

- `alias`
- `unalias`
- `trap`
- `getopts`

Also missing or incomplete:

- full `set`
- full `read`
- full `printf`
- full `test`
- full `command`
- real `exec`
- job-aware `wait`
- real `times`

## 7. Shell options and modes

### Supported

- Shell option state exists.
- `pipefail` supported as a Bash compatibility option.
- Bash compatibility mode plumbing exists.
- Bash `[[ ... ]]` baseline.
- Bash arrays runtime model baseline.

### Partial / missing for POSIX

- POSIX `set` options are largely missing:
  - `-e` errexit
  - `-f` noglob
  - `-u` nounset
  - `-x` xtrace
  - `-v` verbose
  - `-C` noclobber
  - `-a`, `-b`, `-m`, `-n`, etc. as applicable
- Positional parameter setting via `set -- ...` is missing.

## 8. Interactive behavior and job control

### Supported / baseline

- REPL skeleton.
- Syntax highlighting.
- Completion contexts.
- History/autosuggestion baseline.
- External simple commands inherit terminal stdio in CLI/REPL mode.
- Foreground process group handoff for simple inherited-stdio external commands.
- Rush survives SIGINT while idle/interactive; foreground children get default signal behavior.

### Partial

- Process groups currently apply to simple external commands, not full pipelines/jobs.
- Background jobs are not implemented.
- Stopped jobs and job table are missing.
- Terminal modes are not saved/restored beyond foreground pgrp handoff.

### Missing / gaps

- Full job control:
  - process groups for foreground pipelines
  - background execution `&`
  - job table
  - `jobs`, `fg`, `bg`
  - stopped process handling
  - terminal mode save/restore per job
- Signal handling model for pipelines and asynchronous lists.

## 9. Error handling and diagnostics

### Supported

- Parser diagnostics with source spans.
- Incomplete input detection for interactive use.
- Command-not-found returns `127` in simple commands and failed pipeline stage spawn.
- Missing pipeline stage spawn cleanup fixed.

### Partial

- POSIX-specified shell error consequences are not modeled in detail.
- Expansion errors such as `${var:?word}` currently produce a baseline expansion failure rather than POSIX shell diagnostic text and exit behavior.
- Redirection errors and special builtin errors need stricter shell behavior.
- Some CLI inherited-stdio paths now write per-command output directly; capture-mode tests still intentionally model output through `CommandResult`.

## 10. Recommended next roadmap batches

### Batch A: POSIX `set` and option semantics

1. Implement shell positional parameter state outside function frames.
2. Implement `set -- ...` and update `$#`, `$@`, `$*`, `$1` outside functions.
3. Implement `set -f` / `set +f` noglob and wire it into pathname expansion.
4. Implement `set -C` / `set +C` noclobber and `>|` override.
5. Implement baseline `set -u` nounset.
6. Implement baseline `set -e` errexit.
7. Implement baseline `set -x` xtrace and `set -v` verbose.

### Batch B: Redirection and fd correctness

1. Implement arbitrary fd redirections and save/restore.
2. Implement close redirections (`n<&-`, `n>&-`).
3. Implement `<>` read-write redirection.
4. Extend real fd semantics to more capture/test paths where practical.
5. Consider anonymous fd or pipe-backed here-doc materialization.

### Batch C: Arithmetic and expansion correctness

1. Add arithmetic variable lookup.
2. Add arithmetic assignment and broader operators.
3. Harden unquoted `$@`/`$*` edge cases.
4. Expand pathname behavior for slash components and POSIX edge cases.
5. Add `~user` tilde lookup if desired.

### Batch D: Remaining POSIX builtins

1. Add `trap` baseline.
2. Add `alias` and `unalias` with parser integration.
3. Add `getopts`.
4. Deepen `read`, `printf`, `test`, `command`, `exec`, `wait`, and `times`.

### Batch E: Job control and interactive shell

1. Process groups for foreground pipelines.
2. Background asynchronous lists with `&`.
3. `$!` and job-aware `wait`.
4. Job table and job status reporting.
5. `jobs`, `fg`, `bg`.
6. Stopped job handling and terminal mode save/restore.

### Batch F: Parser/CST precision

1. Structured `case` item CST nodes.
2. Pipeline negation `!`.
3. Alias substitution timing and reserved-word interaction.
4. Strict POSIX grammar diagnostics mode separate from recovery/tooling mode.
5. More complete here-doc parser integration.

## Suggested immediate priorities

For the next milestone, the best sequence is:

1. POSIX `set` and option semantics, starting with `set --`, `set -f`, and `set -C`.
2. Redirection follow-through for arbitrary fds, close redirections, `<>`, and `>|`.
3. Job-control prerequisites: async `&`, `$!`, and job-aware `wait`.
4. Remaining builtins: `trap`, `alias`, `unalias`, `getopts`.
5. Parser precision: structured `case` items and `! pipeline`.
