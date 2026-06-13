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
