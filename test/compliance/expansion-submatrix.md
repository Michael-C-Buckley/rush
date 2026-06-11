# POSIX expansion compliance submatrix

This submatrix expands the `area=expansion` rows in `posix-shell.tsv`. It tracks POSIX expansion phases, current Rush coverage, and gaps that should drive corpus and implementation work.

POSIX expansion order is broadly: tilde expansion, parameter expansion, command substitution, arithmetic expansion, field splitting, pathname expansion, and quote removal, with context-specific exceptions.

## Summary

| POSIX area | manifest rows | current status | primary gaps |
| --- | --- | --- | --- |
| Tilde expansion | `expansion-tilde`, `expansion-assignment-prefix-context`, `expansion-tilde-named-user` | baseline | unset HOME edge cases |
| Parameter expansion | `expansion-parameter-*`, `extensions-parameter-expansion` | supported; extensions out of scope | larger parser work and non-POSIX extension implementation tracked outside POSIX scoring |
| Special parameters | `expansion-special-params`, `expansion-positionals-*` | supported | none known for the tracked POSIX-first surface |
| Command substitution | `expansion-command-substitution`, `expansion-command-substitution-newline-trim`, `lex-backquote` | supported | none known for the tracked POSIX-first surface |
| Arithmetic expansion | `expansion-arithmetic` | baseline | POSIX diagnostic behavior for invalid/nonnumeric expressions, overflow semantics, exact nested legacy-backquote diagnostics |
| Field splitting | `expansion-field-splitting-*` | supported/baseline | broad interactions with special parameters |
| Pathname expansion | `expansion-pathname-*` | supported | bytewise matching model; locale-specific collation is intentionally out of scope for current evidence |
| Quote removal | `expansion-quote-removal`, `lex-quotes` | baseline | recursive contexts, escaped newline interactions |

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
- `expansion-parameter-word-nesting-quote-context` (supported)

Supported corpus rows include plain and braced variable references, unset/null behavior, defaults, assignment, alternate/length, null-colon behavior, pattern removal including ASCII POSIX character classes, nested operator words, and `${parameter:?word}` diagnostic word expansion with non-interactive exit. The nested-word corpus covers command substitutions containing right braces, nested braced defaults, arithmetic substitutions used as word operands, assignment/alternate word operands, pattern-removal operands containing quoted right braces or command substitutions, and quoted operator words that suppress field splitting/pathname expansion for their own bytes. The `errors-expansion` row is supported by negative corpus cases for unset/null parameter errors in ordinary commands, malformed or unsupported braced substitutions such as `${}`/`${v/}`/`${v:1}`, representative non-POSIX extension rejections such as `${v/a/X}`/`${v^^}`/`${!name}`/`${!prefix*}`/`${v@Q}`, POSIX/default-mode rejection of `${v[0]}`, unterminated parameter expansions whose word contains a command substitution with `}`, invalid assignment attempts to positional/special parameters when `${parameter:=word}` or `${parameter=word}` would need to assign, redirection target words, assignment words, for-loop word lists, case subjects and patterns, and command substitutions, plus representative special-builtin coverage.

Non-POSIX extension tracking:

- `extensions-parameter-expansion` is an out-of-scope manifest row so Bash/Yash compatibility work does not affect POSIX scoring.
- Extension-mode support should eventually cover string-oriented substring `${parameter:offset[:length]}`, replacement `${parameter/pattern/repl}`, case modification `${parameter^}`/`${parameter,}`, indirect expansion `${!name}`, and name-prefix enumeration `${!prefix*}` forms. Bash mode now has a minimal indexed-array slice for arithmetic `name[index]=word` assignment subscripts, including unquoted whitespace inside assignment subscripts, and `${name[index]}` expansion subscripts against the array runtime model. Broader Bash array behavior, including compound assignment, negative relative indices, whole-array expansion, and array-specific parameter operations, remains outside this baseline. POSIX/default mode still rejects representative `${name[index]}` cases with `parameter: bad substitution` negative-corpus coverage.
- Transformation flags such as `${parameter@Q}` are not in Rush's planned extension-mode scope for now; keep them as unsupported negative coverage until a concrete compatibility use case justifies design work.

Follow-up work outside the supported POSIX parameter-expansion score:

- full parser integration for recursive token-recognition and extension-mode forms remains larger work.
- larger parameter syntax work remains outside the POSIX baseline and should be implemented only behind explicit extension-mode support.

The `expansion-parameter-error` detailed row and `expansion-parameter-error-unset` spec row are supported by negative corpus cases covering unset and null parameters, expanded diagnostic words, unquoted multi-word braced words, focused bad-substitution diagnostics for unsupported or malformed braced forms, and cannot-assign diagnostics for assignment operators targeting positional or special parameters.

Follow-up tasks: broader parser and non-POSIX parameter-extension implementation tasks.

## Special parameters and positional fields

Manifest rows:

- `expansion-special-params`
- `expansion-positionals`
- `expansion-positionals-braced-multi-digit` (supported)
- `expansion-positionals-quoted-at`
- `expansion-positionals-quoted-star`
- `expansion-positionals-unquoted-at-star`

Rush has supported spec-clause coverage for `$?`, `$$`, `$!`, `$0`, braced multi-digit positional parameters such as `${10}`, quoted `$@`, quoted `$*`, and unquoted `$@`/`$*` with custom IFS. The braced multi-digit coverage also guards that unbraced `$10` remains `$1` followed by literal `0`, mixed malformed forms such as `${1abc}` stay on the bad-substitution diagnostics path, and assignment operators reject positional/special targets only when an assignment would actually be needed.

Rush retains empty fields for unquoted `$*` when non-whitespace IFS delimiters are produced by empty positional parameters. POSIX.1-2024 permits empty fields from `@` and `*` expansion to be discarded in field-splitting contexts, so this behavior is tracked in POSIX-only corpus rather than differential comparison-shell corpus because dash/yash/ksh discard those fields while bash and Rush retain them.

Remaining broader expansion work:

- deeper interactions with field splitting and quote removal still belong to broader expansion audits.

Future positional-specific edge cases should get narrower spec-clause rows if they need separate scoring.

## Command substitution

Manifest rows:

- `expansion-command-substitution`
- `lex-command-substitution`
- `lex-backquote`

Current coverage includes `$()`, nested dollar-parentheses substitutions, escaped nested legacy backquote substitutions, legacy backquote backslash-newline line continuation and escape handling, splitting of command substitution output, quoted command substitution, quoted backquotes, case-pattern parens inside `$()`, compound-command substitution bodies in representative contexts, and propagation of nested expansion diagnostics/status from command substitutions. Command-substitution expansion failures are documented as subshell consequences: the substitution exits before later substitution commands, stderr is surfaced, assignment-only status follows the failed substitution, and the invoking shell continues. Unterminated dollar-parentheses and backquote substitutions have negative-corpus diagnostics.

Remaining gaps: none known for the tracked POSIX-first command substitution surface. Undefined or extension behavior around malformed legacy backquote contents remains outside the POSIX support claim.

## Arithmetic expansion

Manifest row: `expansion-arithmetic`

Current coverage includes precedence, variable lookup, assignment side effects, compound assignment, comparisons, logical, bitwise, shifts, ternary, comma operator support, octal/hex constants, and POSIX arithmetic-expression preprocessing of nested parameter expansions and command substitutions before evaluation. The recursive preprocessing behavior was checked against dash, bash `--posix`, and yash for braced defaults, unbraced `$name`, command substitution output, legacy backquote output, backslash-newline continuation, and expression-valued parameter text produced by explicit parameter expansion. Variable values referenced by arithmetic identifiers are intentionally narrower: POSIX integer constants are accepted, unset/null variables evaluate as zero, and nonnumeric values, expression-valued strings, or literal nested substitution text in variable values fail instead of being recursively evaluated. Negative coverage includes invalid operators, invalid variable values, quoted arithmetic tokens, quote bytes that remain in the expression, escaped `$`/`${...`/backquote initiators that must stay literal, unmatched raw legacy-backquote diagnostics after escaped literal backquotes, malformed parameter syntax inside arithmetic, and `${parameter:?word}` failures inside arithmetic. Invalid arithmetic expansion in a current-shell expansion context stops non-interactive execution; inside command substitution it exits only the substitution subshell and propagates diagnostics/status.

Remaining gaps:

- exact POSIX diagnostic wording and consequences for more arithmetic syntax failures;
- divide-by-zero behavior;
- integer overflow and signedness decisions.

Portability note: dash rejects expression-valued arithmetic variables such as `x='1 + 2'; echo $((x))`, bash `--posix` recursively evaluates them, and yash prints the raw value in the audited mode. Rush follows the POSIX-required integer-constant subset and treats expression-valued variable contents as invalid rather than adopting one divergent extension.

## Field splitting

Manifest rows:

- `expansion-field-splitting`
- `expansion-field-splitting-ifs-whitespace`
- `expansion-field-splitting-ifs-nonwhitespace`
- `expansion-field-splitting-empty-ifs`

Current corpus covers newline splitting, leading/trailing IFS whitespace trimming, comma/colon splitting, adjacent non-whitespace delimiters producing empty fields, generated empty field removal, quoted generated/literal empty preservation, empty IFS disabling splitting, literal IFS bytes adjacent to expansions, arithmetic and command substitution output splitting, and quoted/unquoted `$@` and `$*` interactions.

Remaining gaps: none known for the tracked POSIX field-splitting surface; broader recursive expansion/parser interactions are tracked by adjacent expansion rows.

## Pathname expansion

Manifest rows:

- `expansion-pathname`
- `expansion-pathname-ordering`
- `expansion-pathname-dotfiles`
- `expansion-pathname-slash-components`
- `expansion-pathname-bracket-expressions`
- `expansion-pathname-escaped-metacharacters`

Rush has supported pathname expansion coverage for sorted bytewise results, recursive slash-component matching, leading-dot rules, unmatched literals, bracket range/negation expressions, ASCII POSIX character classes, and escaped metacharacters remaining literal.

Remaining cases:

- sort order is bytewise deterministic today; locale collation behavior should be documented if Rush later becomes locale-aware;
- absolute-path patterns and permission-denied directories need portable policy decisions;
- deeper directory edge cases should be added as spec-clause corpus cases.

## Quote removal

Manifest rows:

- `expansion-quote-removal`
- `lex-quotes`

Current coverage includes single quotes, double quotes, escaped spaces, explicit quoted empty fields, double-quote backslash handling for special and non-special characters, escaped-newline continuation, quoted command substitutions including inner quotes and legacy backquotes, quote handling in nested parameter operator words, recursive function and command-substitution bodies, case and parameter pattern literalization, and here-doc delimiter quote removal including mixed quoting and preserved non-special backslashes inside double quotes.

Remaining gaps:

- no POSIX-first quote-removal gaps are currently tracked for the representative supported row; add narrower spec-clause rows if a new edge case is found.

## Promotion guidance

Expansion rows should not move to `supported` while they are `coarse` or high risk. Promote individual `spec_clause` rows first, after adding unit coverage plus POSIX expected-output corpus cases. Differential corpus cases should be added only when comparison shells agree or when diagnostics/status are stable enough.
