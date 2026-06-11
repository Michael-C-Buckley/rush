# POSIX Shell Audit

Date: 2026-06-11

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

- `zig build test --summary none`: passing
- `scripts/check-compliance-manifest.sh`: `417` rows
- `scripts/check-posix-corpus.sh`: `425` expected-output POSIX cases
- `scripts/check-posix-negative-corpus.sh`: `237` expected-error POSIX cases (`1` Linux-only `/dev/full` case skipped on macOS)
- `scripts/check-system-shell-corpus.sh`: `303` cases, `606` comparisons across dash and bash POSIX mode

Current compliance report snapshot:

- tracked items: `417`
- scored POSIX items: `413`
- supported: `406`
- baseline: `3`
- partial: `3`
- missing: `1`
- out of scope: `4`
- strict supported only: `98.3%`
- practical supported+baseline: `99.0%`
- weighted progress: `99.0%`

Recent notable capabilities:

- Real external command spawning with PATH lookup and foreground terminal handoff for inherited-stdio simple commands.
- Real OS fd plumbing for external redirections, pipelines, and mixed builtin/external pipelines.
- Real fd save/restore redirections for CLI inherited-stdio builtins, functions, subshells, brace groups, if/for/while/until/case compound commands, and arbitrary shell-visible fds.
- Redirection support for `<`, `>`, `>>`, `>|`, `<&`, `>&`, `n<&-`, `n>&-`, and `<>` baseline behavior.
- Here-doc support with ordered pending bodies, POSIX delimiter quote removal, quoted delimiter behavior, tab stripping for `<<-`, expansion for unquoted bodies, and safe fd materialization.
- POSIX compound command execution baseline: `if`, `while`, `until`, `for`, `case`, functions, subshells, and brace groups.
- Structured CST nodes for key compound forms including `case_item` arms.
- POSIX pipeline negation with `!`; non-last shell-implemented pipeline stages run in an isolated pipeline environment, while Rush preserves documented last-stage current-shell side effects for non-foreground mixed pipelines.
- Baseline asynchronous external, builtin, and compound command execution with `&`, `$!`, visible background job records, `jobs`, `fg`, `bg`, and `wait` for pid operands.
- POSIX parameter expansion operators, nested operator-word span recognition, pattern removal with nested/quoted operands and ASCII POSIX character classes, `${parameter:?word}` diagnostics, focused malformed braced-substitution diagnostics, invalid assignment diagnostics for positional/special parameter assignment attempts, braced multi-digit positional parameters such as `${10}`, command substitution via `$()` and legacy backquotes including representative nested and compound-command contexts, arithmetic baseline with nested parameter/command preprocessing plus representative quote/backslash handling, IFS-aware field splitting, pathname expansion baseline including ASCII POSIX character classes, quoted command substitution in double quotes, and quoted/unquoted `$@`/`$*` positional field behavior including POSIX-permitted unquoted `$*` empty-field retention.
- Non-POSIX extension forms are excluded from POSIX scoring and tracked separately in `BASH_COMPAT.md`; representative unsupported substring, replacement, case modification, indirect expansion, name-prefix, and transform-flag forms currently diagnose `parameter: bad substitution` in the negative corpus. Indexed array assignment and expansion are supported only in Bash mode for arithmetic subscript expressions, including unquoted whitespace inside assignment subscripts; POSIX/default mode keeps the existing bad-substitution negative coverage for `${name[index]}`.
- Initial process environment import, command-prefix assignment semantics, POSIX special builtin assignment persistence, global positional parameters via `set --`, logical `PWD`/`OLDPWD`, and core special parameters `$?`, `$$`, `$!`, and `$0`.
- POSIX builtins now include supported `.`, `export`, `readonly`, `unset`, `umask`, `times`, `trap`, `getopts`, `eval`, and `exec` plus baseline `command`, `exit`, `shift`, `wait`, `alias`, `unalias`, `jobs`, `fg`, `bg`, and `kill` coverage.
- POSIX shell options baseline for `allexport`, `errexit`, `noglob`, `noclobber`, `noexec`, `nounset`, and `xtrace`, plus supported `verbose` input echo and reusable supported-option listing.
- Prompt prototype support scoped so prompt DSL commands are only available during prompt rendering.
- Cross-target compile-only coverage is tracked by `zig build cross-check`, which runs native tests and compiles the test binary for representative Linux, macOS, FreeBSD, OpenBSD, and NetBSD targets. Foreign-target runtime validation remains separate follow-up work; use `scripts/check-runtime-portability.sh` on actual Linux/BSD hosts and record the host evidence separately from the compile-only compliance row.

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
- Quote tokenization and quote removal for the POSIX-first surface:
  - single quotes, double quotes, adjacent quoted/unquoted segments, and empty quotes preserve word unity
  - backslash escapes and backslash-newline continuation
  - double-quoted expansion contexts suppress field splitting while retaining parameter and command substitution recognition
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

### Missing / gaps

- Full POSIX token recognition state machine:
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
- `case` execution covers POSIX pattern lists, bracket expressions including ASCII POSIX character classes, optional leading parenthesis, empty arms, empty case item lists, final arms without `;;`, nested case bodies, reserved-word subject words, and trailing compound-command redirections.
- `for` execution covers POSIX explicit and omitted word lists, empty lists, quoted and reserved-looking literal word-list entries, nested compound bodies, loop-control and exit-status behavior, and trailing compound-command redirections.

### Partial / gaps

- Function definitions use body source slicing and reparse at call time; semantics work for baseline tests but are not yet a fully lowered function body IR.
- Async execution has real external-command baseline, forked builtin/compound jobs where IO/fork context is available, and pid/job metadata.
- Strict POSIX syntax-error consequences are covered under `--posix-strict`; the default parser still favors recovery/incomplete-input behavior for tooling.

## 3. Expansions

POSIX expansion order broadly includes tilde expansion, parameter expansion, command substitution, arithmetic expansion, field splitting, pathname expansion, and quote removal, with context-dependent exceptions.

### Supported / baseline

- Tilde expansion for `~` and `~/...` using `HOME`, empty `HOME`, quoted/non-initial literal cases, assignment contexts after `=` and `:`, and `~user` lookup through the POSIX user database when libc support is available.
- Parameter expansion:
  - `$name`
  - `${name}`
  - global and function positional parameters `$1`, `$#`, `$@`, `$*`
  - `set --` global positional assignment and function-local positional frames, including function-local `set --` and `shift`
  - quoted `$@` multi-field behavior
  - quoted `$*` joining with first `IFS` character
  - unquoted `$@`/`$*` field behavior, including embedded, zero, empty-parameter, custom-IFS, and POSIX-permitted unquoted `$*` empty-field retention cases
  - core special parameters `$?`, `$$`, `$!`, `$0`
  - `${var:-word}`
  - `${var-word}`
  - `${var:=word}`
  - `${var=word}`
  - `${parameter:=word}` / `${parameter=word}` reject positional or special parameters when the expansion would need to assign to them
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
  - expression text is preprocessed for nested parameter expansion, command substitution, and arithmetic expansion results before arithmetic evaluation in the dash/bash/yash-compatible cases covered by corpus tests
  - shell variable values used by identifier are accepted when they form POSIX integer constants; unset or null variables evaluate as zero, while nonnumeric values, expression-valued strings such as `1 + 2`, and literal nested substitution text in variable values produce arithmetic diagnostics instead of being recursively evaluated
  - arithmetic-expression backslash processing follows the POSIX double-quote-like subset in representative cases: backslash-newline is removed, escaped `$` remains literal instead of starting a nested expansion, legacy backquotes still perform command substitution, unmatched raw legacy backquotes after escaped literal backquotes are classified as backquote substitution syntax errors, and quote bytes that remain in the arithmetic expression produce invalid-expression diagnostics rather than being quote-removed
- Command substitution with `$()` including nested parsing and executor-backed execution.
- Legacy backquote command substitution, including escaped nested backquotes and backslash-newline line continuation in representative cases.
- Command substitution inside double quotes, preserving the quoted field.
- Field splitting honors `IFS`, including empty IFS and non-whitespace delimiters.
- Pathname expansion using current directory glob support for `*`, `?`, ranges, negated bracket expressions, and ASCII POSIX character classes.
- Quote removal after expansions, including single and double quotes, escaped spaces and escaped newlines, explicit empty fields, field-splitting suppression, quoted command substitutions including inner quotes and legacy backquotes, nested parameter operator words, recursive function and command-substitution bodies, and case/parameter pattern literalization.
- Here-doc expansion for unquoted delimiters; quoted delimiters suppress expansion.
- Expansion error consequences are covered for current-shell contexts including ordinary words, redirection targets, assignment words, for-loop word lists, case subjects and patterns, nounset, `${parameter:?word}`, malformed or unsupported braced parameter substitutions, invalid `${parameter:=word}` / `${parameter=word}` assignment attempts to positional or special parameters, invalid arithmetic expansion, and invalid arithmetic variable values. Command-substitution expansion failures exit only the substitution subshell while surfacing diagnostics and assignment-only status. Interactive expansion failures abort the current command without exiting the prompt loop.

Shell comparison note: dash, bash, and yash agree that assignment forms such as `${1:=x}` and `${10:=x}` are errors when the positional parameter is unset or null, but they expand normally when the parameter already has a usable value. `${1=x}` similarly errors only when the positional is unset. Special parameters follow the same assignment-needed rule in the portable subset Rush now covers; comparison shells differ on some extension edge cases such as empty `$@` with the no-colon form, so Rush keeps focused negative coverage on assignment-needed cases.

### Partial / gaps

- Expansion order is modeled but still simplified around some not-yet-audited nested constructs beyond the current POSIX representative coverage.
- Parameter expansion `word` portions are recursively expanded and now preserve representative nested braced expansions, command substitutions containing right braces, arithmetic substitutions, quoted right braces, and quoted field-splitting/pathname suppression; arithmetic-expression preprocessing now recursively handles nested parameter and command substitutions plus focused quote/backslash edge cases in representative POSIX cases. Non-POSIX extension syntax remains larger tracked work, but it is not a POSIX gap for the supported parameter-expansion rows.
- Non-POSIX extension forms are intentionally outside the POSIX claim. Rush should eventually support string-oriented substring `${parameter:offset[:length]}`, replacement `${parameter/pattern/repl}`, case modification `${parameter^}`/`${parameter,}`, and indirect/name-prefix operations `${!name}`/`${!prefix*}` in an extension mode. Bash mode has a minimal indexed-array slice for arithmetic `name[index]=word` assignment subscripts, with unquoted whitespace allowed inside the subscript, and `${name[index]}` expansion subscripts against the array runtime model; broader Bash array semantics such as compound assignment, negative relative indices, whole-array expansion, and array-specific parameter operations remain outside this baseline. Transformation flags such as `${parameter@Q}` are not in Rush's planned extension-mode scope for now; keep them as unsupported negative coverage until a concrete compatibility use case justifies design work. Representative unsupported extension forms reject with bad-substitution diagnostics and are tracked in `extensions-parameter-expansion` instead of counted as POSIX gaps; `${name[index]}` remains on that bad-substitution path outside Bash mode.
- Pathname expansion remains bytewise; locale-specific collation, equivalence classes, and multi-character collating elements are outside the current model.
- Unquoted `$@`/`$*` behavior is acceptable for common cases but still needs more spec-derived edge-case coverage.

### Missing / gaps

- No POSIX-first quote-removal gaps are currently tracked for the supported representative rows; add narrower spec-clause rows if a new edge case is found.
- Full pathname expansion semantics.
- POSIX-accurate diagnostics for additional expansion error forms beyond the currently covered malformed braced-parameter and arithmetic cases.

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
- CLI inherited-stdio builtins, functions, subshells, brace groups, and if/for/while/until/case compound commands use temporary OS fd mutation and restore for supported fd forms, including shared input offsets across mixed builtin/external consumers.
- Shell-visible fd tracking prevents internal fds from being accidentally exposed as shell fds.
- Non-interactive redirection error consequences are covered for ordinary builtins, external commands, compound commands, function calls and bodies, `<>`, here-doc materialization, async commands, pipelines, AND-OR lists, negation, `$?`, `errexit`, and special-builtin shell exit behavior. Rush intentionally uses non-zero status `1` for many non-special redirection failures where dash reports `2`; POSIX only requires non-zero.
- Output write failures after redirection setup succeeds are covered in inherited-stdio unit tests with a portable broken-pipe fd harness and in a Linux-gated negative corpus case using `/dev/full` as an actual file target: regular builtins diagnose `write`, return status `1`, and let following commands run; functions and brace groups propagate the failed redirected write as their status; pipelines record the failed stage status, including `pipefail` and last-stage behavior. External command write failures remain delegated to the external utility and OS signal/write semantics.

### Partial / gaps

- Capture-mode tests still use captured-result modeling in some paths instead of true inherited process fds.
- `/dev/full`-style file targets are represented by a Linux-gated negative corpus case; macOS validation skips that case while the portable synthetic fd tests keep cross-platform coverage of Rush's shell-implemented write-failure consequences.
- Exact parser-level here-doc token timing remains tracked under lexical analysis, but no here-doc redirection execution gap is currently tracked.

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
- `export`, `unset`, and `env` utility behavior.
- Subshell executes with copied executor state.
- Brace group executes in current executor.
- Functions have call frames and positional parameters.
- Global positional parameters via `set --`.
- POSIX special builtin classification and assignment persistence are supported across all 15 special builtins.
- POSIX special builtin error consequences are modeled for the audited XCU 2.8.1/2.15 cases: expansion/redirection failures, invalid options or operands where applicable, and utility-semantic failures stop non-interactive execution across all 15 special builtins.
- Exit status propagation and `$?` baseline.
- Logical `PWD`/`OLDPWD` tracking for `cd`/`pwd`, including valid inherited logical `PWD`, `CDPATH`, `cd -`, and `-L`/`-P` behavior.
- `$!` tracks the most recent real background external command pid.
- `wait` can wait for tracked background pids and job IDs, returns operand statuses, and returns zero after waiting for all known jobs when invoked without operands.
- `exec` replaces the Rush process image for CLI inherited-stdio external command paths, preserves assignment operands in the replacement environment, reports command-not-found and permission-denied failures with shell-exit consequences, and applies redirection-only fd changes to the current shell.
- `command` utility behavior covers `-p`, `-v`, `-V`, clustered POSIX options, `--`, multiple lookup operands, aliases, shell functions, reserved words, special and regular builtins, default-path lookup without replacing child `PATH`, function lookup suppression, declaration-utility assignment expansion for wrapped `export`/`readonly`, and suppression of special-builtin assignment-prefix persistence and shell-exit error consequences.

### Partial / gaps

- PATH hashing/caching and POSIX command search edge cases are missing.
- Background job metadata is enough for `$!`/`wait`, but not for full job control.

### Missing / gaps

- Full signal environment semantics.
- Command search cache/hash behavior if desired later.

## 6. Builtins

### Supported / baseline

Implemented or partially implemented:

- `:`
- `.` / `source`
- `break` / `continue` loop control, including nested and over-depth counts, outside-loop no-op behavior, status propagation, and operand diagnostics
- `cd`
- `pwd`
- `return`
- `echo`
- `false`
- `true`
- `export` utility behavior, including assignment-context `name=value` operands, exported-name marking, `-p` reusable listing, and diagnostics
- `unset` utility behavior, including default variable mode, `-v`, `-f`, readonly protection, and diagnostics
- `env` utility behavior, including exported-only environment printing, `-i`, assignment operands, PATH operand lookup, utility arguments, invoked-utility status propagation, and diagnostics
- `set` baseline for shell options and positional parameters
- `test` / `[` POSIX-defined argument-count grammar, unary and binary primaries, file predicates, and diagnostics
- `read` baseline with non-interactive IFS/backslash, `-r`, EOF, and diagnostic coverage
- `printf` baseline
- `command` utility behavior, including lookup modes, alias/function/special-builtin classification, default-path lookup, function suppression, declaration-utility expansion, and special-builtin property suppression
- `eval` utility behavior, including argument concatenation, empty status, current-shell assignment/stdin/redirection side effects, exit, and special-builtin failure consequences
- `exec` utility behavior, including process replacement for CLI inherited external commands, assignment environment, non-interactive shell-exit failures, permission-denied status, no-return function context, and redirection-only current-shell fd changes
- `exit` baseline
- `readonly` utility behavior, including readonly marking/listing, reusable `-p` output, readonly protection for unset and later assignments, and POSIX-first non-interactive consequences for assignment-prefix and loop-variable assignment failures
- `shift` baseline
- `umask` with current-shell mask effects, subshell/pipeline isolation, octal/default output, `-S`, POSIX permission-bit symbolic operands, and diagnostics
- `wait` builtin with tracked pid/job operands, no-operand all-job semantics, and last-operand status
- `times` POSIX-style resource usage output
- `getopts` utility behavior, including OPTIND initialization/reset, clusters, separate and attached arguments, silent/non-silent diagnostics, explicit arg operands, and `--` termination
- `trap` utility behavior with reusable listing output, reset/null-ignore actions, `EXIT` trap execution, common catchable signal traps, invalid signal diagnostics, and subshell/command-substitution reset behavior
- `alias` / `unalias` utility behavior, including POSIX-format listing/query output, reusable value quoting, POSIX alias-name operands, current-shell removal, `unalias -a`, and `unalias --` operands

### Partial / gaps

- `echo` has minimal behavior and intentionally avoids complex option/escape variations.
- `read` has broad non-interactive POSIX coverage for IFS splitting, backslash/cooked versus `-r`, EOF status, option/operand diagnostics, and readonly assignment failure. The remaining broad-row gap is interactive terminal input/continuation prompting.
- `printf` supports common conversions/escapes including representative floating-point conversions, but not POSIX C integer constants or full format grammar details.
- `set` has the POSIX non-interactive short option baseline, positional handling, interactive `ignoreeof`, interactive `notify` polling for background job status while the editor is active, interactive `monitor` process groups for tracked async jobs, and explicit no-effect compatibility handling for obsolescent `-h`/`nolog`, but not the full optional interactive/User Portability surface (`vi` editing mode and complete job-control terminal semantics).
- Exact `times` CPU values are runtime- and host-dependent; coverage asserts POSIX output shape and centisecond formatting rather than fixed accounting totals.
- Full POSIX alias substitution token timing remains partial; the builtin `alias`/`unalias` utility row is supported separately from those parser-level timing edge cases.

## 7. Shell options and modes

### Supported / baseline

- Shell option state exists.
- `pipefail` supported as a Bash compatibility option.
- Bash compatibility mode plumbing exists.
- Bash `[[ ... ]]` baseline.
- Bash arrays runtime model baseline.
- Bash-mode indexed array assignment/expansion baseline for arithmetic subscript expressions, including assignment-subscript whitespace.
- POSIX option baseline:
  - `set -- ...`
  - `set -a` / `set +a` allexport
  - `set -f` / `set +f` noglob
  - `set -C` / `set +C` noclobber
  - `set -u` / `set +u` nounset
  - `set -e` / `set +e` errexit baseline
  - `set -n` / `set -o noexec` noexec syntax-check behavior
  - `set -x` / `set +x` xtrace baseline
  - `set -v` / `set +v` verbose input echo as script-file and standard-input lines are read
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
- Xtrace exact output ordering is baseline-only.
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
- Non-interactive redirection failures now have negative-corpus coverage for ordinary utility continuation, compound and function redirections, status propagation, `errexit`, pipelines, `<>`, here-doc materialization, and special-builtin shell exit behavior.
- Redirected output write failures after successful setup/open report shell-visible `write` diagnostics for shell-implemented commands and non-zero command/stage status in the inherited-stdio executor; external utility write failures are left to the child process.
- Nounset produces a baseline unset-parameter diagnostic and exits non-interactive execution.
- `${parameter:?word}` expands the diagnostic word, reports the parameter name, and exits non-interactive execution.
- `${parameter:=word}` / `${parameter=word}` report a parameter diagnostic and exit non-interactive execution when they would need to assign to a positional or special parameter; set/non-null positional parameters continue to expand normally, including braced multi-digit positionals.
- Expansion failures in redirection target words, assignment words, for-loop word lists, case subjects/patterns, and invalid arithmetic expansion exit non-interactive execution in current-shell contexts.
- Expansion failures inside command substitutions exit the substitution subshell, surface diagnostics to the invoking shell, and preserve assignment-only command-substitution status without exiting the invoking shell.
- Interactive expansion failures abort the current command without setting `pending_exit`, allowing the prompt loop to continue.
- Special builtin expansion, redirection, invalid option/operand, and utility-semantic failures now stop non-interactive execution for the audited POSIX special-builtin set.
- Negative POSIX corpus covers syntax, expansion, redirection, and builtin diagnostic cases.
- Strict POSIX mode reports status 2 for covered syntax diagnostics and stops non-interactive execution before earlier or later commands in the submitted script run; default recovery parsing remains intentionally permissive for tooling.

### Partial / gaps

- `/dev/full`-style file write failures now have Linux-gated negative corpus coverage, while portable inherited-fd unit coverage keeps macOS validation stable.
- Some CLI inherited-stdio paths now write per-command output directly; capture-mode tests still intentionally model output through `CommandResult`.

## 10. Recommended next roadmap batches

The detailed backlog lives in Tend and the machine-readable status lives in `test/compliance/posix-shell.tsv`. Current non-completion implementation priorities are:

### Batch A: Parser/CST precision

1. `#157` Lower function bodies into structured IR instead of reparsing source slices.
2. Continue strict diagnostics only where explicitly requested by `--posix-strict` so editor recovery remains useful.

### Batch B: Pathname and expansion edge cases

1. `#159` Deepen pathname expansion POSIX edge cases, especially slash components, dotfiles, and unmatched patterns.
2. Keep diagnostics and shell-error consequences in the negative corpus when they are not differential-safe.

### Batch C: Compliance evidence growth

1. `#169` Import dash-derived POSIX language smoke cases.
2. `#170` Import BusyBox ash-inspired builtin and redirection cases.
3. `#171` Add spec-clause examples for current high-risk POSIX gaps.
4. Run `scripts/check-runtime-portability.sh` on real Linux and BSD hosts for the cross-target portability matrix and record the host OS/version, Zig version, comparison shells, skipped cases, and failures in Tend or release notes; the current supported portability row only claims compile coverage.
5. Keep `POSIX_AUDIT.md` as prose context and avoid duplicating generated compliance totals beyond snapshot refreshes.

### Batch D: Job-control and error-consequence depth

1. Deepen pipeline/asynchronous-list signal-handling edge cases beyond the supported job-control utility rows.
2. Deepen non-special redirection consequence edge cases and add expansion diagnostic wording cases beyond the supported consequence matrix.

Keep adding POSIX corpus, negative corpus, and manifest evidence alongside each behavior change.
