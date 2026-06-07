# Rush Architecture

Rush is a shell aiming for Bash compatibility with better UX: Bash syntax with Fish-like usability.

## Direction

- Start at the POSIX shell layer, then add Bash compatibility incrementally.
- Design the parser for both execution and interactive tooling, especially completions and syntax highlighting.
- Design the interpreter so Bash-specific behavior can be added later without rewriting the POSIX core.

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
