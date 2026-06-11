# POSIX expansion compliance submatrix

This submatrix expands the `area=expansion` rows in `posix-shell.tsv`. It tracks POSIX expansion phases, current Rush coverage, and gaps that should drive corpus and implementation work.

POSIX expansion order is broadly: tilde expansion, parameter expansion, command substitution, arithmetic expansion, field splitting, pathname expansion, and quote removal, with context-specific exceptions.

## Summary

| POSIX area | manifest rows | current status | primary gaps |
| --- | --- | --- | --- |
| Tilde expansion | `expansion-tilde`, `expansion-assignment-prefix-context`, `expansion-tilde-named-user` | baseline | unset HOME edge cases |
| Parameter expansion | `expansion-parameter-*` | supported/baseline | nested word edge cases and broad-operator audit |
| Special parameters | `expansion-special-params`, `expansion-positionals-*` | supported/baseline | broad positional row remains baseline because unquoted `$*` empty-field behavior diverges across shells |
| Command substitution | `expansion-command-substitution`, `expansion-command-substitution-newline-trim`, `lex-backquote` | baseline | nested legacy backquote behavior, parsing contexts |
| Arithmetic expansion | `expansion-arithmetic` | baseline | POSIX diagnostic behavior for invalid/nonnumeric expressions, overflow semantics |
| Field splitting | `expansion-field-splitting-*` | supported/baseline | broad interactions with special parameters |
| Pathname expansion | `expansion-pathname-*` | supported | bytewise matching model; locale-specific collation is intentionally out of scope for current evidence |
| Quote removal | `expansion-quote-removal`, `lex-quotes` | baseline | recursive contexts, escaped newline interactions, here-doc delimiter contexts |

## Tilde expansion

Manifest row: `expansion-tilde`

Current Rush behavior supports `~` and `~/...` using `HOME`, with POSIX and differential corpus coverage in `expansion-tilde-home`. Named-user expansion is covered by `expansion-tilde-named-user`.

Recommended cases:

- assignment contexts where tilde expansion is required or not required
- unset/empty `HOME` behavior
- explicit decision on whether to support `~user`

## Parameter expansion

Manifest rows:

- `expansion-parameter-basic`
- `expansion-parameter-default-alternate` (supported)
- `expansion-parameter-assignment-operator` (supported)
- `expansion-parameter-pattern` (supported)
- `expansion-parameter-error`
- `expansion-parameter-error-unset`

Supported corpus rows include defaults, assignment, alternate/length, null-colon behavior, pattern removal, and `${parameter:?word}` diagnostic word expansion with non-interactive exit. The `errors-expansion` row is supported by negative corpus cases for unset/null parameter errors in ordinary commands, malformed or unsupported braced substitutions such as `${}`/`${v/}`/`${v:1}`, invalid assignment attempts to positional/special parameters when `${parameter:=word}` or `${parameter=word}` would need to assign, redirection target words, assignment words, for-loop word lists, case subjects and patterns, and command substitutions, plus representative special-builtin coverage. Nested parameter-word hardening remains tracked by the broad baseline row.

Remaining high-risk gaps:

- nested `word` portions need broader recursive expansion coverage.
- larger parameter syntax work, such as substring or pattern-substitution extensions, remains outside the POSIX baseline.

The `expansion-parameter-error` detailed row and `expansion-parameter-error-unset` spec row are supported by negative corpus cases covering unset and null parameters, expanded diagnostic words, unquoted multi-word braced words, focused bad-substitution diagnostics for unsupported or malformed braced forms, and cannot-assign diagnostics for assignment operators targeting positional or special parameters.

Follow-up tasks: broader nested parameter-word hardening tasks.

## Special parameters and positional fields

Manifest rows:

- `expansion-special-params`
- `expansion-positionals`
- `expansion-positionals-braced-multi-digit` (supported)
- `expansion-positionals-quoted-at`
- `expansion-positionals-quoted-star`
- `expansion-positionals-unquoted-at-star`

Rush has supported spec-clause coverage for `$?`, `$$`, `$!`, `$0`, braced multi-digit positional parameters such as `${10}`, quoted `$@`, quoted `$*`, and unquoted `$@`/`$*` with custom IFS. The braced multi-digit coverage also guards that unbraced `$10` remains `$1` followed by literal `0`, mixed malformed forms such as `${1abc}` stay on the bad-substitution diagnostics path, and assignment operators reject positional/special targets only when an assignment would actually be needed.

Remaining high-risk gaps:

- the broad `expansion-positionals` row remains baseline because unquoted `$*` empty-field behavior diverges across comparison shells;
- deeper interactions with field splitting and quote removal still belong to broader expansion audits.

Follow-up work should add narrower spec-clause rows if these edge cases need separate scoring.

## Command substitution

Manifest rows:

- `expansion-command-substitution`
- `lex-command-substitution`
- `lex-backquote`

Current coverage includes `$()`, splitting of command substitution output, quoted command substitution, quoted backquotes, case-pattern parens inside `$()`, a backquote backslash fix, and propagation of nested expansion diagnostics/status from command substitutions. Command-substitution expansion failures are documented as subshell consequences: the substitution exits before later substitution commands, stderr is surfaced, assignment-only status follows the failed substitution, and the invoking shell continues.

Remaining gaps:

- nested command substitutions in more grammar contexts;
- legacy backquote nesting and escape behavior;
- diagnostics for unterminated substitutions in strict versus recovery modes.

## Arithmetic expansion

Manifest row: `expansion-arithmetic`

Current coverage includes precedence, variable lookup, assignment side effects, compound assignment, comparisons, logical, bitwise, shifts, ternary, comma operator support, and negative diagnostics for invalid or currently unsupported arithmetic forms. Invalid arithmetic expansion in a current-shell expansion context stops non-interactive execution; inside command substitution it exits only the substitution subshell and propagates diagnostics/status.

Remaining gaps:

- exact POSIX diagnostic wording and consequences for more arithmetic syntax failures;
- divide-by-zero behavior;
- integer overflow and signedness decisions;
- nonnumeric variable behavior is Rush/Bash-like and not fully differential-safe.

## Field splitting

Manifest rows:

- `expansion-field-splitting`
- `expansion-field-splitting-ifs-whitespace`
- `expansion-field-splitting-ifs-nonwhitespace`
- `expansion-field-splitting-empty-ifs`

Current corpus covers newline splitting, leading/trailing IFS whitespace trimming, comma/colon splitting, adjacent non-whitespace delimiters producing empty fields, generated empty field removal, quoted generated/literal empty preservation, and empty IFS disabling splitting.

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

Current coverage includes single quotes, double quotes, escaped spaces, explicit quoted empty fields, double-quote backslash handling for special and non-special characters, escaped-newline continuation, and common quoted expansion cases.

Remaining gaps:

- quote removal around nested expansion `word` operands;
- here-doc delimiter quote removal versus body expansion;
- recursive parser contexts such as command substitutions and function bodies.

## Promotion guidance

Expansion rows should not move to `supported` while they are `coarse` or high risk. Promote individual `spec_clause` rows first, after adding unit coverage plus POSIX expected-output corpus cases. Differential corpus cases should be added only when comparison shells agree or when diagnostics/status are stable enough.
