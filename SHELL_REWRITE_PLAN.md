# Rush shell rewrite plan

This branch is a clean shell-core rewrite. The old `src/shell` implementation is
not the design source of truth; POSIX, conformance tests, reference shells, and
Git history are.

## Goals

- Build a fast POSIX shell core with a direct execution model.
- Prefer fewer representations and fewer allocations over architectural seams
  that duplicate the shell grammar.
- Keep Rush extensible, but redesign extension APIs around the new core instead
  of preserving old command-plan/state-delta APIs.
- Use external shell-script conformance tests as the primary behavior contract.

## Non-goals

- Do not preserve the old command-plan architecture.
- Do not preserve the old state-delta/output-routing architecture.
- Do not preserve old internal extension, completion, runner, or interactive
  session APIs just to keep compatibility.
- Do not use `std.Io` as the evaluator's effects boundary.

## Kept assets

- `tests/` conformance suites and harness.
- `share/rush/` scripts, completions, functions, and config assets.
- Low-level editor/line-editing implementation under `src/editor/`.
- History storage code where it is independent of shell internals.
- Git history for old Rush implementation archaeology.

## Deleted/rewritten assets

- `src/shell/` and the old `src/shell.zig` facade.
- The old runner and executable wiring.
- The old runtime port/vtable layer.
- The old completion engine integration with parser/expansion/state.
- The old extension API and handlers.
- The old interactive shell session/startup/prompt integration.
- Shell-internal fuzz targets that encode old plan/delta types.

## New architecture

The new shell should be shaped as:

```text
source
  -> lexer/parser
  -> small AST close to shell grammar
  -> direct evaluator
  -> comptime-known Host effects layer
```

The evaluator should directly walk the AST with functions such as:

```text
evalList
evalAndOr
evalPipeline
evalCommand
evalSimple
evalIf
evalWhile
evalFor
evalCase
evalFunction
```

Small semantic helpers are allowed when they encode real shell rules:

- command lookup/classification
- assignment persistence
- redirection actions and rollback
- pipeline status aggregation
- `errexit` and fatal shell-error policy

They should not become a second AST or broad command-plan language.

## Host effects layer

All evaluation-time host effects go through a comptime-known concrete `Host`
type. The shell evaluator must not call OS, filesystem, process, signal,
terminal, clock, global environment, `std.Io`, or `std.posix` APIs directly.

`RealHost` should call `std.posix` or targeted platform APIs directly. It should
not use `std.Io` in the hot evaluator path. `FakeHost` should implement the same
method contract for Zig tests.

Effects are a value, not a heap-allocated interface. Pointers are only mutable
borrows when needed.

Conceptual shape:

```zig
pub fn Shell(comptime Host: type) type {
    return struct {
        allocator: std.mem.Allocator,
        host: Host,
        state: State,
    };
}
```

Host responsibilities include:

- fd operations: read, write, open, close, dup, pipe
- filesystem operations: cwd, chdir, stat/access, directory iteration
- process operations: fork/spawn/exec/wait, process groups, job-control hooks
- signal operations: dispositions, masks, pending signal polling
- terminal operations: tty checks, foreground pgrp, size, modes
- time/process identity when shell semantics require them

Host does not decide shell semantics such as assignment persistence, special
builtin behavior, `errexit`, variable scoping, or pipeline state isolation.

## Testing policy

Shell behavior should prefer conformance scripts under `tests/`.

If behavior is observable through stdout, stderr, exit status, variable/file
effects, process behavior, or scripts, write a conformance case rather than a Zig
unit test.

Zig tests are for:

- pure helpers
- lexer/parser subroutines
- pattern/glob/arithmetic internals
- runtime/host mechanics with `FakeHost`
- editor, completion, and history internals
- crash regressions or invariants awkward to express as shell scripts

Avoid Zig tests that lock in evaluator architecture or intermediate
representations.

## Reference shell policy

Primary contract:

1. POSIX Issue 8 / POSIX.1-2024 for POSIX mode
2. documented Rush behavior
3. Rush conformance tests

Primary comparison shells:

- dash
- `bash --posix`
- yash

zsh sh emulation is not a primary reference. Use it only for exploratory
compatibility work when explicitly desired.

## Initial implementation order

1. Delete the old shell-coupled architecture.
2. Define new data structures first: source locations, tokens, AST, shell state,
   host effect request/result types, and eval results.
3. Implement enough parser/eval for `rush -c ':'`.
4. Add simple commands, variables, builtins, and external exec.
5. Add redirections.
6. Add expansions.
7. Add lists and compound commands.
8. Add pipelines, subshells, background jobs, functions, traps, and signals.
9. Rebuild extensions, completion, and interactive integration on the new API.
