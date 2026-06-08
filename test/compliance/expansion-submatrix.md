# POSIX expansion compliance submatrix

This submatrix expands the `area=expansion` rows in `posix-shell.tsv`. It tracks POSIX expansion phases, current Rush coverage, and gaps that should drive corpus and implementation work.

POSIX expansion order is broadly: tilde expansion, parameter expansion, command substitution, arithmetic expansion, field splitting, pathname expansion, and quote removal, with context-specific exceptions.

## Summary

| POSIX area | manifest rows | current status | primary gaps |
| --- | --- | --- | --- |
| Tilde expansion | `expansion-tilde` | baseline | `~user`, assignment-word contexts, unset HOME edge cases |
| Parameter expansion | `expansion-parameter-*` | baseline | unquoted braced-word parser edge cases, nested word edge cases, special-builtin consequences |
| Special parameters | `expansion-special-params`, `expansion-positionals-*` | supported/baseline | embedded `$@`/`$*`, empty positionals, deeper custom IFS interactions |
| Command substitution | `expansion-command-substitution`, `lex-backquote` | baseline | trailing-newline trimming edge cases, nested legacy backquote behavior, parsing contexts |
| Arithmetic expansion | `expansion-arithmetic` | baseline | POSIX diagnostic behavior for invalid/nonnumeric expressions, overflow semantics |
| Field splitting | `expansion-field-splitting-*` | baseline | empty-field edge cases, generated-empty fields, interactions with special parameters |
| Pathname expansion | `expansion-pathname-*` | partial/missing | dotfiles, slash components, unmatched patterns, directory ordering edge cases |
| Quote removal | `expansion-quote-removal`, `lex-quotes` | baseline | recursive contexts, escaped newline interactions, here-doc delimiter contexts |

## Tilde expansion

Manifest row: `expansion-tilde`

Current Rush behavior supports `~` and `~/...` using `HOME`. There is no POSIX corpus case linked yet, so this row should remain `baseline` until coverage is added.

Recommended cases:

- `HOME=/tmp; echo ~`
- `HOME=/tmp; echo ~/x`
- assignment contexts where tilde expansion is required or not required
- unset/empty `HOME` behavior
- explicit decision on whether to support `~user`

## Parameter expansion

Manifest rows:

- `expansion-parameter-basic`
- `expansion-parameter-default-alternate`
- `expansion-parameter-assignment-operator`
- `expansion-parameter-pattern`
- `expansion-parameter-error`
- `expansion-parameter-error-unset`

Covered corpus includes defaults, assignment, alternate/length, null-colon behavior, nested default words, pattern removal, and `${parameter:?word}` diagnostic word expansion with non-interactive exit.

Remaining high-risk gaps:

- unquoted spaces in braced parameter `word` portions currently depend on parser word splitting and need hardening;
- nested `word` portions need broader recursive expansion coverage;
- diagnostics should distinguish unset/null parameter cases where POSIX requires it;
- special builtin expansion failures need separate consequences from ordinary command failures.

Follow-up tasks: `#156 Model POSIX special builtin error consequences` and parser/parameter hardening tasks.

## Special parameters and positional fields

Manifest rows:

- `expansion-special-params`
- `expansion-positionals`
- `expansion-positionals-quoted-at`
- `expansion-positionals-quoted-star`
- `expansion-positionals-unquoted-at-star`

Rush has strong baseline coverage for `$?`, `$$`, `$!`, `$0`, `set --`, quoted `$@`, quoted `$*`, and unquoted `$@`/`$*` with custom IFS.

Remaining high-risk gaps:

- embedded unquoted `$@`/`$*` with literal prefixes/suffixes;
- zero positional parameters;
- empty positional parameters in more command contexts;
- deeper interactions with field splitting and quote removal.

Follow-up work should add narrower spec-clause rows if these edge cases need separate scoring.

## Command substitution

Manifest rows:

- `expansion-command-substitution`
- `lex-command-substitution`
- `lex-backquote`

Current coverage includes `$()`, splitting of command substitution output, quoted command substitution, quoted backquotes, and a backquote backslash fix.

Remaining gaps:

- exact trailing newline removal semantics for multiple newlines;
- nested command substitutions in more grammar contexts;
- legacy backquote nesting and escape behavior;
- diagnostics for unterminated substitutions in strict versus recovery modes.

## Arithmetic expansion

Manifest row: `expansion-arithmetic`

Current coverage includes precedence, variable lookup, assignment side effects, compound assignment, comparisons, logical, bitwise, shifts, ternary, and comma operator support.

Remaining gaps:

- POSIX diagnostic consequences for invalid arithmetic syntax;
- divide-by-zero behavior;
- integer overflow and signedness decisions;
- nonnumeric variable behavior is Rush/Bash-like and not fully differential-safe.

## Field splitting

Manifest rows:

- `expansion-field-splitting`
- `expansion-field-splitting-ifs-whitespace`
- `expansion-field-splitting-ifs-nonwhitespace`
- `expansion-field-splitting-empty-ifs`

Current corpus covers newline splitting, comma/colon splitting, and empty IFS disabling splitting.

Remaining gaps:

- leading/trailing IFS whitespace combinations;
- adjacent non-whitespace IFS delimiters and empty fields;
- generated empty fields from parameter expansion;
- interactions with quoted/unquoted `$@` and `$*`.

## Pathname expansion

Manifest rows:

- `expansion-pathname`
- `expansion-pathname-ordering`
- `expansion-pathname-dotfiles`
- `expansion-pathname-slash-components`

Rush has basic sorted pathname expansion. Dotfile and slash-component semantics are explicitly `missing` in the manifest until audited.

Required cases:

- `*` should not match leading-dot names unless pattern explicitly begins with `.`;
- patterns with `/` should match path components correctly;
- unmatched patterns should remain literal;
- bracket expressions and escaping should be audited against POSIX pattern rules;
- sort order should be deterministic and locale decision should be documented.

Follow-up task: `#159 Deepen pathname expansion POSIX edge cases`.

## Quote removal

Manifest rows:

- `expansion-quote-removal`
- `lex-quotes`

Current coverage includes single quotes, double quotes, escaped spaces, and common quoted expansion cases.

Remaining gaps:

- quote removal around nested expansion `word` operands;
- escaped-newline behavior across lexing and expansion;
- here-doc delimiter quote removal versus body expansion;
- recursive parser contexts such as command substitutions and function bodies.

## Promotion guidance

Expansion rows should not move to `supported` while they are `coarse` or high risk. Promote individual `spec_clause` rows first, after adding unit coverage plus POSIX expected-output corpus cases. Differential corpus cases should be added only when comparison shells agree or when diagnostics/status are stable enough.
