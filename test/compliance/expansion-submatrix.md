# POSIX expansion compliance submatrix

This submatrix expands the `area=expansion` rows in `posix-shell.tsv`. It tracks POSIX expansion phases, current Rush coverage, and gaps that should drive corpus and implementation work.

POSIX expansion order is broadly: tilde expansion, parameter expansion, command substitution, arithmetic expansion, field splitting, pathname expansion, and quote removal, with context-specific exceptions.

## Summary

| POSIX area | manifest rows | current status | primary gaps |
| --- | --- | --- | --- |
| Tilde expansion | `expansion-tilde`, `expansion-assignment-prefix-context` | baseline | `~user`, unset HOME edge cases |
| Parameter expansion | `expansion-parameter-*` | supported/baseline | nested word edge cases, special-builtin consequences, broad-operator audit |
| Special parameters | `expansion-special-params`, `expansion-positionals-*` | supported/baseline | broad positional row remains baseline because unquoted `$*` empty-field behavior diverges across shells |
| Command substitution | `expansion-command-substitution`, `expansion-command-substitution-newline-trim`, `lex-backquote` | baseline | nested legacy backquote behavior, parsing contexts |
| Arithmetic expansion | `expansion-arithmetic` | baseline | POSIX diagnostic behavior for invalid/nonnumeric expressions, overflow semantics |
| Field splitting | `expansion-field-splitting-*` | baseline | empty-field edge cases, generated-empty fields, interactions with special parameters |
| Pathname expansion | `expansion-pathname-*` | supported | bytewise matching model; locale-specific collation is intentionally out of scope for current evidence |
| Quote removal | `expansion-quote-removal`, `lex-quotes` | baseline | recursive contexts, escaped newline interactions, here-doc delimiter contexts |

## Tilde expansion

Manifest row: `expansion-tilde`

Current Rush behavior supports `~` and `~/...` using `HOME`, with POSIX and differential corpus coverage in `expansion-tilde-home`.

Recommended cases:

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

- nested `word` portions need broader recursive expansion coverage;
- special builtin expansion failures need separate consequences from ordinary command failures.

The `expansion-parameter-error` detailed row and `expansion-parameter-error-unset` spec row are supported by negative corpus cases covering unset and null parameters, expanded diagnostic words, and unquoted multi-word braced words.

Follow-up tasks: `#156 Model POSIX special builtin error consequences` and broader nested parameter-word hardening tasks.

## Special parameters and positional fields

Manifest rows:

- `expansion-special-params`
- `expansion-positionals`
- `expansion-positionals-quoted-at`
- `expansion-positionals-quoted-star`
- `expansion-positionals-unquoted-at-star`

Rush has supported spec-clause coverage for `$?`, `$$`, `$!`, `$0`, quoted `$@`, quoted `$*`, and unquoted `$@`/`$*` with custom IFS.

Remaining high-risk gaps:

- the broad `expansion-positionals` row remains baseline because unquoted `$*` empty-field behavior diverges across comparison shells;
- deeper interactions with field splitting and quote removal still belong to broader expansion audits.

Follow-up work should add narrower spec-clause rows if these edge cases need separate scoring.

## Command substitution

Manifest rows:

- `expansion-command-substitution`
- `lex-command-substitution`
- `lex-backquote`

Current coverage includes `$()`, splitting of command substitution output, quoted command substitution, quoted backquotes, and a backquote backslash fix.

Remaining gaps:

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

Current corpus covers newline splitting, leading/trailing IFS whitespace trimming, comma/colon splitting, adjacent non-whitespace delimiters producing empty fields, generated empty field removal, quoted empty preservation, and empty IFS disabling splitting.

Remaining gaps:

- interactions with quoted/unquoted `$@` and `$*`.

## Pathname expansion

Manifest rows:

- `expansion-pathname`
- `expansion-pathname-ordering`
- `expansion-pathname-dotfiles`
- `expansion-pathname-slash-components`
- `expansion-pathname-bracket-expressions`
- `expansion-pathname-escaped-metacharacters`

Rush has supported pathname expansion coverage for sorted bytewise results, recursive slash-component matching, leading-dot rules, unmatched literals, basic bracket range/negation expressions, and escaped metacharacters remaining literal.

Remaining cases:

- sort order is bytewise deterministic today; locale collation behavior should be documented if Rush later becomes locale-aware;
- absolute-path patterns and permission-denied directories need portable policy decisions;
- deeper directory edge cases should be added as spec-clause corpus cases.

## Quote removal

Manifest rows:

- `expansion-quote-removal`
- `lex-quotes`

Current coverage includes single quotes, double quotes, escaped spaces, escaped-newline continuation, and common quoted expansion cases.

Remaining gaps:

- quote removal around nested expansion `word` operands;
- here-doc delimiter quote removal versus body expansion;
- recursive parser contexts such as command substitutions and function bodies.

## Promotion guidance

Expansion rows should not move to `supported` while they are `coarse` or high risk. Promote individual `spec_clause` rows first, after adding unit coverage plus POSIX expected-output corpus cases. Differential corpus cases should be added only when comparison shells agree or when diagnostics/status are stable enough.
