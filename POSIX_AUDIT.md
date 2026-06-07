# POSIX Shell Audit

Date: 2026-06-07

This audit compares Rush's current implementation against the POSIX Shell Command Language at a practical feature level. It is not a legal/normative copy of the specification; it is a gap analysis for implementation planning.

Status legend:

- **Supported**: implemented with tests or exercised by corpus.
- **Partial**: recognizable implementation exists, but important POSIX semantics are missing.
- **Missing**: not implemented or only placeholder behavior.
- **Out of scope for now**: POSIX-adjacent or optional interactive/job-control behavior not needed for the current milestone.

## Current snapshot

Validated before this audit:

- `zig build test --summary all`: `124/124` passing
- `zig build corpus --summary all`: passing
- `zig build cross-check --summary all`: passing for Linux/macOS/BSD compile checks

Recent notable capabilities:

- Real external command spawning.
- Real file-descriptor plumbing for external redirections and pipelines.
- Mixed builtin/external pipelines using OS pipes and worker threads.
- Foreground terminal handoff for inherited-stdio external commands.
- Interactive SIGINT survival baseline.
- POSIX compound command execution baseline: `if`, `while`, `until`, `for`, `case`, functions, subshells, brace groups.
- Here-doc baseline with ordered pending bodies, quoted delimiter behavior, tab stripping for `<<-`, and expansion for unquoted bodies.
- POSIX parameter expansion operator baseline.

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

### Partial

- Reserved words are recognized mostly by parser context/string matching rather than a fully POSIX grammar phase.
- Newline/list handling works for common constructs, but the parser remains permissive and recovery-oriented rather than a strict POSIX grammar.
- Double-quote behavior is simplified. POSIX requires special handling for `$`, `` ` ``, `\`, newline, and quote contexts.
- Backquote command substitution is missing.
- Alias substitution is missing, which affects token recognition and reserved-word parsing order.

### Missing / gaps

- Full POSIX token recognition state machine:
  - recursive quote tracking across all grammar contexts
  - here-doc token/body collection exactly at parser level
  - backquote substitution parsing
  - alias substitution timing
- Complete reserved-word grammar disambiguation.
- Full handling of escaped newlines / line continuation.

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
- Parser CST now includes nested list bodies for key compound command regions.

### Partial

- `case` execution supports basic patterns, but case CST arms are still represented as a raw list-ish region rather than structured case item nodes with pattern/body children.
- `for` supports word lists, but no advanced Bash forms; POSIX baseline only.
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
  - special parameters via executor lookup for positional-function contexts (`$1`, `$#`, `$@`, `$*`)
  - `${var:-word}`
  - `${var-word}`
  - `${var:=word}`
  - `${var=word}`
  - `${var:+word}`
  - `${var+word}`
  - `${var:?word}` baseline error
  - `${#var}`
- Arithmetic expansion baseline for integer expressions:
  - `+`, `-`, `*`, `/`, `%`, parentheses, unary `+`/`-`
- Command substitution with `$()` including nested parsing and executor-backed execution.
- Field splitting using default IFS whitespace.
- Pathname expansion using current directory glob support for `*`, `?`, bracket classes.
- Quote removal baseline.
- Here-doc expansion for unquoted delimiters; quoted delimiters suppress expansion.

### Partial

- Expansion order is modeled but simplified, especially around quote contexts and field splitting.
- IFS is hard-coded to default whitespace; shell variable `IFS` is not honored.
- Parameter expansion `word` portions are recursively expanded, but error text and side effects are minimal.
- `$@` and `$*` are currently represented as joined strings in function frames, not as full multi-field semantics.
- `$$`, `$?`, `$!`, `$0` are incomplete or missing depending on context.
- Arithmetic expansion does not resolve shell variables inside arithmetic expressions.
- Pathname expansion lacks full POSIX details such as leading-dot rules, slash-component behavior, locale/collation details.
- Tilde expansion does not support `~user`.

### Missing / gaps

- IFS variable semantics, including non-whitespace IFS chars and empty fields.
- Full quote-aware expansion and field generation.
- Full special parameters:
  - `$?`
  - `$$`
  - `$!`
  - `$0`
  - true `$@`/`$*` field behavior inside/outside double quotes.
- Additional parameter expansion forms:
  - `${var%word}`
  - `${var%%word}`
  - `${var#word}`
  - `${var##word}`
- Command substitution backquote form.
- Arithmetic variable lookup and assignment/operators beyond the current baseline.
- Full pathname expansion semantics.

## 4. Redirection

### Supported

- Input redirection `<`.
- Output redirection `>`.
- Append redirection `>>` using real `O_APPEND`.
- Stderr redirection `2>`.
- Pipeline-stage redirections overriding pipe endpoints.
- Here-docs:
  - `<<`
  - `<<-`
  - ordered pending bodies
  - quoted delimiter disables expansion
  - unquoted body expansion baseline
- External commands use real file descriptors.

### Partial

- Descriptor duplication operators `<&` and `>&` have partial captured-result semantics for some cases; not full fd duplication at OS level across all execution modes.
- `<>` and `>|` are tokenized but not fully implemented.
- Builtin redirections are still mostly modeled through captured byte streams rather than temporarily mutating the shell process fd table.
- Here-docs are materialized through a temporary file helper with a fixed filename (`rush-heredoc.tmp`), which is not robust under concurrency/reentrancy.

### Missing / gaps

- Full fd semantics for builtins/functions/compound commands:
  - save/restore fds
  - arbitrary fd numbers
  - close redirections (`n<&-`, `n>&-`)
  - duplicate input/output fds exactly
- `<>` read-write redirection.
- `>|` noclobber interaction once `set -C` exists.
- Here-doc storage should use a safe unique temp file, pipe, or anonymous fd strategy.

## 5. Command search and execution environment

### Supported

- Builtin dispatch.
- Function dispatch.
- External command spawn with PATH search through `std.process.spawn`.
- Assignment-only commands mutate shell environment.
- `export`, `unset`, `env` baseline.
- Subshell executes with copied executor state.
- Brace group executes in current executor.
- Functions have call frames and positional parameters.

### Partial

- Rush does not import the parent process environment into `Executor.env` at shell startup, so scripts differ from normal shells for `$HOME`, `$PATH` as shell variables, `$USER`, etc. External command lookup still uses parent PATH via Zig spawn.
- Assignment preceding an external command (`VAR=value cmd`) semantics are incomplete: POSIX requires temporary environment for that command without mutating shell variables unless assignment-only/special builtin rules apply.
- Special builtins are not modeled separately from regular builtins.
- Exit status propagation works for many cases, but `$?` is not wired as a special parameter.

### Missing / gaps

- Initialize shell variables/environment from process environment.
- Correct environment construction for external command spawn.
- Temporary assignment semantics for utilities and functions.
- POSIX special builtin semantics.
- `command` builtin / command lookup controls.
- `exec` builtin.
- `eval` builtin.
- `trap` and signal environment semantics.

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
- `set` baseline for `pipefail`
- `test` / `[` baseline
- `read` baseline
- `printf` baseline

### Partial

- `echo` has minimal behavior and intentionally avoids complex option/escape variations.
- `read` supports simple field assignment and `-r` acceptance but not full POSIX options/IFS/backslash behavior.
- `printf` supports common conversions/escapes, but not full POSIX format grammar.
- `test` baseline lacks many operators and edge cases.
- `set` is mostly shell option plumbing, not full positional parameter or option behavior.
- `env` does not support arguments/options.
- `cat` is a helper builtin for tests/pipelines, not a POSIX shell builtin requirement.

### Missing POSIX special/regular builtins

High-priority missing:

- `alias`
- `unalias`
- `command`
- `eval`
- `exec`
- `exit` as builtin semantics in scripts/REPL
- `readonly`
- `shift`
- `times`
- `trap`
- `umask`
- `wait`

Also missing or incomplete:

- `getopts`
- full `set`
- full `read`
- full `printf`
- full `test`

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
  - job table
  - background execution `&`
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
- Expansion errors such as `${var:?word}` currently produce an internal expansion failure rather than POSIX shell diagnostic text and exit behavior.
- Redirection errors and special builtin errors likely need stricter shell behavior.

## 10. Recommended next roadmap batches

### Batch A: POSIX execution environment correctness

1. Import initial process environment into shell variable state.
2. Implement temporary assignment semantics for command prefixes.
3. Implement POSIX special builtin classification and error consequences.
4. Add `command`, `exec`, `eval`, `exit` builtins.
5. Add `$?`, `$$`, `$!`, `$0` special parameters.

### Batch B: Expansion correctness

1. Implement IFS variable semantics.
2. Implement true `$@`/`$*` multi-field behavior, especially in double quotes.
3. Implement `${var%word}`, `${var%%word}`, `${var#word}`, `${var##word}`.
4. Implement arithmetic variable lookup and broader arithmetic operators.
5. Implement backquote command substitution.
6. Harden quote removal/double-quote behavior.

### Batch C: Redirection and fd correctness

1. Implement arbitrary fd redirections and close/dup semantics.
2. Implement `<>` redirection.
3. Implement `>|` and `set -C` noclobber.
4. Apply real save/restore fd semantics to builtins/functions/compound commands.
5. Replace fixed here-doc temp filename with safe anonymous/unique fd strategy.

### Batch D: POSIX builtins

1. `readonly`.
2. `shift`.
3. `umask`.
4. `trap`.
5. `wait`.
6. `times`.
7. `getopts`.
8. Full `read`, `printf`, `test`, `set` behavior.

### Batch E: Job control and interactive shell

1. Process groups for foreground pipelines.
2. Background asynchronous lists with `&`.
3. Job table and job status reporting.
4. `jobs`, `fg`, `bg`.
5. Stopped job handling and terminal mode save/restore.

### Batch F: Parser/CST precision

1. Structured `case` item CST nodes.
2. Alias substitution timing and reserved-word interaction.
3. Strict POSIX grammar diagnostics mode separate from recovery/tooling mode.
4. More complete here-doc parser integration.

## Suggested immediate priorities

For POSIX conformance, the biggest observable gaps are:

1. Initial environment import and command-prefix assignment semantics.
2. Special parameters (`$?`, `$$`, `$!`, `$0`) and true `$@` behavior.
3. IFS semantics and field splitting correctness.
4. Real fd save/restore for builtin/compound redirections.
5. POSIX special builtins (`command`, `eval`, `exec`, `readonly`, `trap`, `umask`, `wait`, `shift`).

These should become the next Tend roadmap batch.
