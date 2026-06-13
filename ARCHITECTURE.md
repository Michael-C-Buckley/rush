# Rush Architecture

Rush is a shell aiming for Bash compatibility with better UX: Bash syntax with Fish-like usability.

## Direction

- Start at the POSIX shell layer, then add Bash compatibility incrementally.
- Design the parser for both execution and interactive tooling, especially completions and syntax highlighting.
- Design the interpreter so Bash-specific behavior can be added later without rewriting the POSIX core.
- Keep production shell execution centered on the semantic shell core and shrink
  any remaining legacy executor dependencies as semantic coverage expands.

## Shell execution redesign contract

The shell redesign is a semantic shell core with an imperative POSIX runtime
boundary. The contract below freezes the vocabulary, dependency direction,
mutation rules, and assertion model for the implementation tasks that follow.

### Dependency direction

Shell execution flows in one direction:

```text
parser/IR -> semantic shell core -> runtime ports -> POSIX adapters
```

- `parser/IR` owns syntax, source spans, and parsed command structure.
- The `semantic shell core` owns shell semantics: planning, expansion-facing
  decisions, state deltas, control flow, and commit/discard rules.
- `runtime ports` are narrow dependency-injected interfaces for low-level
  effects the core cannot perform itself, such as file descriptor operations,
  process creation, waiting, environment lookup, cwd changes, and signal/job
  control primitives.
- `POSIX adapters` are the only layer that translates runtime ports into
  platform syscalls and POSIX process behavior.

The semantic core must not depend on POSIX adapters directly. Dependency
injection belongs at runtime ports, not around parser, IR, expansion,
completion, UI, or high-level shell semantics.

### Vocabulary

- `ShellState` is the authoritative mutable model of a shell instance: shell
  variables and export state, positional parameters, shell options, traps,
  aliases/functions as they become supported, cwd/logical pwd state, job table
  state, the last status values visible to shell semantics, and other state
  whose lifetime is the current shell environment.
- `EvalContext` is the immutable or scoped evaluation frame for a single
  semantic operation. It names the current `ExecutionTarget`, input source,
  source-span/diagnostic context, option mode, loop/function/sourced-script
  nesting, and any temporary environment or redirection scope needed to decide
  how a plan should be evaluated.
- `ExecutionTarget` says where observable state changes are allowed to land:
  the current shell, a subshell environment, or a child process. It is the
  semantic answer to “who owns mutations from this command?”
- `CommandOutcome` is the complete result of evaluating a command plan:
  wait status or shell status, emitted diagnostics, produced `StateDelta`, and
  the resulting `ControlFlow`. It is not just an exit code.
- `ControlFlow` represents non-local shell flow produced by evaluation:
  continue normally, exit the shell/subshell, return from a function or sourced
  script, break/continue loops, or stop because a fatal shell error requires it.
- `StateDelta` is the explicit set of semantic mutations produced by a command:
  variable assignments, export/readonly changes, positional parameter changes,
  option changes, cwd changes, function/alias table changes, job table changes,
  and last-status updates. It can be committed to an allowed target or
  discarded, but it must not be applied implicitly while planning.
- `CommandPlan` is the side-effect-free semantic plan for a command or compound
  command after parser/IR interpretation and before runtime effects. It names
  the command kind, assignments, arguments, redirections, expansion obligations,
  builtin/function/external dispatch choice when known, and the
  `ExecutionTarget` required by shell semantics.
- `RedirectionPlan` is the ordered, validated plan for descriptor mutations and
  file operations. It preserves POSIX ordering, records rollback requirements,
  and separates diagnostic-producing open/dup decisions from the POSIX adapter
  calls that perform them.
- `PipelinePlan` is the semantic plan for a pipeline: ordered command plans,
  pipe wiring, negation, pipeline status rules, and which segments must run in
  children or may run in the current shell under later extension rules.
- `runtime ports` are the small imperative boundary used by execution to ask
  the host to do work: open/close/dup descriptors, create pipes, fork/spawn,
  exec, wait, inspect/set cwd, read environment, configure signals/process
  groups, and perform other unavoidable OS interactions. Ports return ordinary
  shell diagnostics for expected user/runtime failures and assertion failures
  only for violated Rush invariants.

### Mutation boundary and commit rules

All semantic mutation flows through `StateDelta` and an explicit commit point.
Planning is pure with respect to `ShellState`; runtime effects are isolated
behind runtime ports; commits happen only after the semantic operation reaches a
commit/discard decision.

- Current-shell execution commits the allowed `StateDelta` to the current
  `ShellState`. Builtins and compound commands that POSIX requires to affect the
  current environment must target this path. Redirections for current-shell
  commands must be restored or rolled back before the commit point completes.
- Subshell execution starts from a snapshot of `ShellState`, commits deltas only
  to the subshell snapshot, and discards that snapshot when the subshell
  completes. Only the subshell outcome visible to the parent, such as status,
  diagnostics, and pipeline/list control consequences, crosses back.
- Child execution receives only the state needed to build its process
  environment and descriptor table. Child-local mutations are discarded when the
  child exits. The parent observes status, diagnostics, job-table consequences,
  and any explicitly modeled pipe/output effects, not arbitrary child state.

Discard is as important as commit: every plan that targets a subshell or child
must make it impossible to leak child-only mutations into the current
`ShellState`.

### Diagnostics and assertions

Rush/model assertion failures and ordinary shell/user diagnostics are different
classes of failure.

- Assertions catch internal bugs: impossible enum combinations, invalid plan
  shapes, illegal state transitions, descriptor rollback invariants, committing
  a `StateDelta` to the wrong `ExecutionTarget`, or crossing the semantic core
  into a POSIX adapter without going through a runtime port.
- Diagnostics report ordinary shell behavior: parse errors, expansion errors,
  command not found, permission denied, redirection open failures, invalid
  builtin usage, readonly-variable assignment attempts, and POSIX-defined fatal
  shell errors.

Implementation should follow a TigerStyle/TigerBeetle-like posture: assert
invariants at API boundaries, state transitions, plan construction, and
commit/discard points. Assertions are for Rush bugs and should not be used as a
substitute for user-facing diagnostics. Diagnostics must remain data the shell
can report and test; assertions should make invalid internal states unignorable.

### Invariants and property tests to enable

The redesign should make these checks natural to express:

- Planning the same parser/IR input with the same `ShellState` snapshot and
  `EvalContext` produces the same `CommandPlan` without mutating `ShellState`.
- Every `CommandPlan` has exactly one `ExecutionTarget`, and every produced
  `StateDelta` is either committed to that target or explicitly discarded.
- A child-targeted or subshell-targeted command cannot change parent variables,
  cwd, options, functions, aliases, traps, or positional parameters except
  through an explicitly modeled parent-visible outcome.
- Redirection planning preserves left-to-right ordering, and applying then
  rolling back a `RedirectionPlan` restores the descriptor model.
- Pipeline planning preserves command order, pipe ownership, close/rollback
  obligations, negation/status rules, and child/current-shell target
  constraints.
- Diagnostics for ordinary shell errors are reproducible values in
  `CommandOutcome`; assertion failures are not part of the shell language
  surface and should only arise from invalid internal states.
- Production entry-point tests should exercise the semantic shell core through
  parser/IR lowering and runtime ports without requiring parser, IR, expansion,
  completion, or UI movement.

## `src/exec.zig` retirement map

`src/exec.zig` is still imported only by `src/main.zig` (`pub const exec =
@import("exec.zig")`), but that one import covers several different ownership
surfaces. Do not move those surfaces into another single module. Retire them in
the dependency order below, keeping semantic shell state in `src/shell/*`, POSIX
effects in `src/runtime/*`, and interactive/completion glue at the application
edge until it has a narrower home.

### Current external uses and target owners

- `src/main.zig:57`, `src/main.zig:176`, `src/main.zig:6118`,
  `src/main.zig:6426`, `src/main.zig:7698`, and `src/main.zig:7717` use
  `exec.ShellOptions`, `exec.ShoptOptions`, and
  `exec.applyShellOptionName`/`exec.applyShellOptionShort` for CLI parsing,
  interactive startup defaults, editing mode selection, and legacy/semantic
  option conversion. Owner: `src/shell/state.zig` plus a small option parser in
  the shell layer. Blocker: callers must stop depending on `exec.ShellOptions`
  before `exec.Executor.shell_options` can be removed.
- `src/main.zig:251`, `src/main.zig:302`, `src/main.zig:853`,
  `src/main.zig:6139`, `src/main.zig:6486`, `src/main.zig:6792`, and the
  `runScript*` public helpers use `exec.ExitStatus` and `exec.CommandResult` as
  the command-result ABI. Owner: `src/shell/outcome.zig` for shell statuses and
  command outcomes, with a narrow top-level captured-output result for CLI/test
  entry points if needed. Blocker: `main.runScript*`, tests, and the old
  executor bridge must agree on the replacement result type.
- `src/main.zig:6554`, `src/main.zig:6558`, `src/main.zig:6669`,
  `src/main.zig:6722`, `src/main.zig:6835`, and `src/main.zig:7179` use
  `exec.ExecuteOptions` and `exec.ExternalStdio` for a mixed bag of parser
  features, stdio policy, cancellation, script source metadata, interactive
  mode, and completion-provider callbacks. Owner: split by field instead of
  creating a replacement god options struct: semantic invocation/input metadata
  in `src/shell/*`, external stdio/process policy in `src/runtime/*` or
  `src/shell/eval.zig`, and completion callback state in top-level completion
  glue. Blocker: `Executor.executeScriptSlice` still consumes the whole struct.
- `src/main.zig:858` through `src/main.zig:3520`, and the completion debug and
  trace writers around `src/main.zig:3657`, `src/main.zig:4024`,
  `src/main.zig:4155`, `src/main.zig:5002`, `src/main.zig:5180`,
  `src/main.zig:5244`, and `src/main.zig:5831`, use `exec.Executor` as the
  mutable completion registry and use `exec.Completion*` types/functions such as
  `completionEvalContextForInput` and `completionOptionSuppressionForOption`.
  Owner: keep this top-level/completion-owned for now, but detach it from
  `exec.Executor` into a narrow completion state/model in `src/completion.zig`
  plus application glue in `src/main.zig`. Blocker: dynamic providers currently
  execute Rush functions through `Executor` state.
- `src/main.zig:447`, `src/main.zig:494`, `src/main.zig:499`, and
  `src/main.zig:504` adapt interactive history to `exec.HistoryEntry` and
  `exec.CommandHistory`. Owner: `src/history.zig` already owns the data model;
  keep the adapter top-level until `fc` history access is provided to semantic
  builtins without an `Executor` callback.
- `src/main.zig:945`, `src/main.zig:979`, `src/main.zig:1046`,
  `src/main.zig:1100`, `src/main.zig:6123`, `src/main.zig:6150`,
  `src/main.zig:6175`, `src/main.zig:6180`, `src/main.zig:6365`, and
  `src/main.zig:7766` still route prompts, color/style hooks, completion script
  loading, ENV/profile/config sourcing, prompt event hooks, interval hooks, and
  job notifications through `exec.Executor`. Owner: keep at the application edge
  while extracting explicit prompt/config/history/job-control services; shell
  mutations go through `src/shell/state.zig` and POSIX waiting/signals through
  `src/runtime/*`. Blocker: interactive startup and hooks can still run
  arbitrary legacy Rush scripts.
- `src/main.zig:6155`, `src/main.zig:6156`, `src/main.zig:6347`, and
  `src/main.zig:6475` depend on `exec.setTrapSignalWakeFd`,
  `exec.clearTrapSignalWakeFd`, `exec.stopped_jobs_exit_warning`, and signal
  trap execution. Owner: `src/runtime/signal.zig` for wake-fd/signal adapter
  state; shell trap state remains in `src/shell/state.zig`. Blocker: job control
  and pending traps are still stored and executed by `exec.Executor`.
- `src/main.zig:6688`, `src/main.zig:6835`, `src/main.zig:7689`,
  `src/main.zig:7754`, `src/main.zig:7831`, and the many inline tests below
  `src/main.zig:7960` keep `exec.Executor` live as the old execution engine.
  Owner: delete after semantic parity. Blocker: every fallback gate listed below
  must either move into semantic execution or become an explicit unsupported
  diagnostic without needing the legacy bridge.

### Current semantic/legacy fallback gates

- Non-interactive entry (`src/main.zig:6669` and `src/main.zig:6705`) selects
  the semantic path when the invocation is not interactive and external commands
  are allowed. `runSemanticCommandString` (`src/main.zig:6722`) gates
  noexec/verbose/xtrace startup modes, non-shell environment names/NULs,
  parser diagnostics, async non-pipeline statements, unsupported function
  bodies, bash `[[ ]]`, semantic builtins that are still marked unsupported,
  and evaluator `error.Unimplemented`. Unsupported non-interactive execution is
  reported as a command result, not retried through `exec.Executor`.
- Interactive execution (`src/main.zig:6835`) first tries
  `runSemanticInteractiveCommandString` and falls back to
  `runScriptWithExecutor` when that path returns `semanticUnsupported`.
  Interactive-only gates include inherited/captured stdio requirements,
  `stdin_script_file == null`, no pending exit, no verbose/xtrace/errexit
  state, no parser diagnostics, and `semanticPreflightUnsupported(..., true)`.
- `legacy_fallback_gates == true` in `semanticPreflightUnsupported`
  (`src/main.zig:7463`) keeps these shapes on the legacy bridge: compound
  command statements, assignment-bearing commands, unsupported builtins,
  production expansion forms containing command/parameter/arithmetic/special
  parameter expansion, redirection-only commands, simple or compound
  redirections, parser-rejected or dynamically guarded function definitions,
  bash `[[ ]]`, and non-pipeline async statements.
- `semanticBodyUnsupportedMessage` (`src/main.zig:7588`) adds post-lowering
  interactive gates for compound redirections, assignment-bearing commands,
  redirections, `read`, `alias`, and `unalias` when legacy gates are enabled.
- `semanticInteractiveProgramUnsupported` (`src/main.zig:7231`) keeps
  interactive execution on `InteractiveShell.executor` when it sees function
  definitions, aliases, arrays used with shell expansion, nounset expansion
  diagnostics, unsupported builtins, external commands, dynamic function lookup,
  or shell function calls. `InteractiveShell` (`src/main.zig:6080`) mirrors
  legacy executor state into `shell.ShellState` before semantic attempts and
  mirrors semantic state back only after a successful semantic command.

### Dependency-ordered checklist

1. Replace `exec.ExitStatus`, `exec.ShellOptions`, `exec.ShoptOptions`, and the
   shell option parsers in `src/main.zig` with `src/shell` types. This unblocks
   the narrower task of removing status/options dependencies from shell-facing
   call sites.
2. Split `exec.ExecuteOptions` by responsibility. Move runtime stdio/process
   policy toward `src/runtime/*`/`src/shell/eval.zig`, semantic source metadata
   toward `src/shell/*`, and completion callbacks toward completion glue.
3. Replace `exec.CommandResult` and `exec.parseDiagnosticsResult` at the public
   `runScript*` and CLI boundaries with either `shell.CommandOutcome` or a
   small top-level captured-output result that does not depend on `Executor`.
4. Extract completion registry/query state from `exec.Executor` into
   completion-owned data structures, then update `CompletionCache`, manifest
   loaders, debug/trace output, and dynamic provider execution to accept that
   state explicitly.
5. Move history/`fc`, prompt rendering, style hooks, config sourcing, event
   hooks, and interval hooks out of `Executor` into explicit interactive-session
   services. Keep them top-level until their state contracts are narrow.
6. Move POSIX signal wake-fd handling, job-control process state, open-fd
   tracking, redirection application, external spawn/exec, and wait behavior
   behind `src/runtime/*` ports used by semantic evaluation.
7. Burn down the fallback gates in semantic order: redirections and
   assignment-bearing commands first, then production expansion gaps, `read` and
   alias timing, compound-command redirections, interactive external/function
   calls, arrays/nounset expansion diagnostics, traps, and job control.
8. Delete `runOldCommandStringWithEnvironment`, `runScriptWithExecutor`, legacy
   executor tests, and finally `src/exec.zig` only after `src/main.zig` no longer
   imports `exec.zig` and `std.testing.refAllDecls(exec)` is gone.

## Parser

The parser should produce a lossless, concrete-ish syntax tree rather than only an execution AST.

Goals:

- Preserve source spans for tokens and nodes.
- Preserve enough trivia and structure to support syntax highlighting and diagnostics.
- Recover from incomplete or invalid input so the REPL can still provide useful feedback.
- Support partial input and cursor-aware queries for completions.
- Make it cheap to answer questions like “what syntactic context is the cursor in?”

The parse layer answers: **what did the user type?**

## Semantic lowering

Parsing should be separate from semantic analysis and execution lowering.

A later analysis/lowering layer should translate the concrete syntax into an execution-oriented representation, resolving shell constructs while preserving source mappings for errors and tooling.

The lowering layer answers: **what shell construct does this represent?**

## Interpreter

The interpreter should implement POSIX shell behavior as the semantic baseline, then expose clear extension points for Bash features.

Initial POSIX-oriented areas:

- Simple commands
- Pipelines
- Lists
- Redirections
- Expansions
- Variables and environments
- Functions
- Builtins
- Exit status and control flow

Bash-specific features should be added incrementally, for example:

- Arrays
- `[[ ... ]]`
- Bash-specific expansion behavior
- Process substitution
- Brace expansion differences
- `shopt`/shell options
- Bash-only builtins and compound commands

Avoid scattering broad `bash_mode` conditionals throughout the interpreter. Prefer explicit extension points for:

- Expansion behavior
- Builtins
- Compound command evaluation
- Options and compatibility modes
- Runtime state

The interpreter answers: **how do we execute it?**

## Interactive UX

The interactive engine should consume parser services directly.

- Syntax highlighting should use token and node spans.
- Completions should use cursor context from partial parses.
- Diagnostics should come from recovery-aware parsing and semantic checks.
- The UX should be helpful by default, closer to Fish, while retaining Bash-compatible syntax and behavior where possible.
