# Bash compatibility

Rush defaults to POSIX behavior. Bash-compatible behavior is opt-in through
`compat.Features.bash()` and should not change POSIX/default-mode parsing,
expansion, execution, or compliance scoring.

This document tracks Bash-compatible features Rush intentionally supports or
plans separately from POSIX compliance. POSIX status remains tracked in
`test/compliance/posix-shell.tsv` and `POSIX_AUDIT.md`.

## Supported in Bash mode

- `[[ ... ]]` conditional command baseline:
  - string equality / inequality
  - glob-style string matching for `==`
  - basic integer comparisons
  - unary `!` forms covered by executor tests
- Indexed array assignment and expansion baseline:
  - `name[index]=word`
  - compound indexed assignment such as `name=(zero one)` and
    `name=([2]=two [5]=five)`
  - compound indexed assignment elements with quotes and empty quoted words,
    such as `name=('two words' "${value}" '')`
  - per-element expansion for compound indexed assignment, including field
    splitting for sequential unquoted elements and scalar expansion for
    `[index]=word` elements
  - arithmetic subscript expressions such as `name[i + 1]=word`
  - subscript expressions containing nested parameter, command, or arithmetic substitutions
  - whitespace inside assignment subscripts, such as `name[ i + 1 ]=word`
  - whitespace-only assignment subscripts as index `0`, such as `name[   ]=word`
  - `${name[index]}` expansion against Rush's array runtime
  - whole-array value expansion with `${name[@]}` and `${name[*]}`
  - quoted whole-array expansion semantics for `"${name[@]}"` and `"${name[*]}"`
  - array length and key operations: `${#name[@]}`, `${#name[index]}`,
    and `${!name[@]}` / `${!name[*]}`
  - `unset 'name[index]'` for individual indexed array elements
  - negative relative subscripts against the current maximum set index, such as
    `${name[-1]}`
  - negative relative subscripts in compound indexed assignment elements after
    an earlier element establishes a maximum index, such as
    `name=([2]=two [-1]=TWO)`
- Indirect and name-prefix parameter expansion baseline:
  - `${!name}` expands the value of the scalar, positional, or special
    parameter named by `name`'s value; empty, unset, or invalid target names
    expand to an empty value unless `nounset` applies
  - when `name`'s value is an indexed-array element target such as
    `arr[index]`, `${!name}` resolves the subscript with the same arithmetic and
    negative-index rules as `${arr[index]}`
  - when `name`'s value is `arr[@]` or `arr[*]`, `${!name}` expands array
    values with the same quoted/unquoted `@` and `*` field behavior as direct
    whole-array value expansion
  - malformed indirect target strings containing array brackets, such as
    `arr[]`, `arr[1`, or `bad-name[0]`, stop with an `invalid variable name`
    parameter diagnostic
  - `${!prefix*}` and `${!prefix@}` enumerate scalar and indexed-array
    variable names with the requested prefix, sorted for deterministic output
  - `*` joins names with the first byte of `IFS`; quoted `@` emits one field
    per matching name, while unquoted forms are still subject to field splitting
- String parameter expansion extensions for scalar, positional, and special
  parameter values:
  - substring `${parameter:offset}` and `${parameter:offset:length}` with
    arithmetic offset/length expressions; negative offsets count back from the
    end of the string, and negative lengths are interpreted as offsets back
    from the end of the string. Bash mode reports
    `length: substring expression < 0` when the computed end precedes the
    start. Rush targets modern Bash 5.x behavior here; macOS Bash 3.2 was
    observed to reject negative scalar lengths. The offset delimiter scanner
    skips nested parameter, command, arithmetic, and quoted constructs,
    including arithmetic ternary `:` operands. Field-producing Bash slices for
    `${@:offset:length}` and `${*:offset:length}` are tracked separately
  - replacement `${parameter/pattern/repl}`, global `${parameter//pattern/repl}`,
    anchored-prefix `${parameter/#pattern/repl}`, and anchored-suffix
    `${parameter/%pattern/repl}` using Rush's existing shell glob pattern matcher;
    the pattern/replacement separator skips quoted and nested `/` constructs
  - ASCII case modification `${parameter^}`, `${parameter^^}`, `${parameter,}`,
    and `${parameter,,}`, including optional pattern operands such as
    `${parameter^^[[:lower:]]}`
- `read -d delimiter` delimiter selection:
  - separate delimiter operand, e.g. `read -d : name`
  - attached/grouped option spelling, e.g. `read -d: name` or `read -rd: name`
  - empty delimiter operand as NUL

## Bash-version-specific diagnostics

- Negative indexed-array subscripts are version-specific in Bash itself. Audit
  evidence from Bash 4.2.46, 4.3.30, and 5.2.26 shows 4.2 resolves negative
  subscripts for parameter expansion but still rejects assignment and `unset`,
  while 4.3+ resolves assignment and `unset` when the current maximum index can
  anchor the negative offset.
- Rush Bash mode targets the modern 5.x resolution rule for supported negative
  subscripts. When a negative subscript cannot resolve because the array has no
  current maximum index, or because the offset is before index 0, Rush emits a
  Bash-style `bad array subscript` diagnostic. Rush normalizes away Bash's
  process-name and line-number prefix, but keeps context-specific subjects such
  as `arr: bad array subscript`, `-1]: bad array subscript`,
  `arr[-1]: bad array subscript`, `[-1]=value: bad array subscript`, and
  `unset: [-1]: bad array subscript`.
- Rush follows Bash 5.x consequences for the audited unresolved negative
  subscript cases: element expansion diagnoses and expands as an empty value;
  `${#missing[-1]}` expands to `0`; `${#arr[-1]}` for an existing empty array
  remains a stopping expansion error; simple assignment such as `arr[-1]=value`
  remains a stopping expansion error; compound assignment diagnoses and skips
  invalid elements while keeping valid elements; and `unset 'arr[-1]'` diagnoses
  with status 1 without stopping the following command, while `unset
  'missing[-1]'` is a quiet no-op.

## Default common-shell compatibility

These choices are accepted in Rush's default/POSIX-facing mode because dash and
Bash POSIX mode both accept them. They are documented as compatibility behavior,
not POSIX compliance claims, and remain excluded from POSIX scoring:

- `printf` ignores sign and space flags on unsigned decimal conversions such as
  `%+u` and `% u`.
- `printf` preserves zero padding on string conversions such as `%05s`. POSIX
  leaves the `0` flag with string conversions undefined.

## Explicitly not POSIX

These features must remain gated behind Bash mode or another future explicit
extension mode. Default/POSIX mode should continue to reject representative
extension forms and keep POSIX corpus expectations independent from Bash
compatibility behavior.

Current examples:

- `${name[index]}` is valid only in Bash mode; default/POSIX mode reports
  `parameter: bad substitution`.
- `read -d` is valid only in Bash mode; default/POSIX mode reports an
  unsupported `read` option.
- `[[ ... ]]` is parsed only in Bash mode.
- `${!name}` and `${!prefix*}` / `${!prefix@}` are valid only in Bash mode;
  default/POSIX mode reports `parameter: bad substitution`.
- `${name:1}`, `${name/pat/repl}`, and `${name^^}` are valid only in Bash mode;
  default/POSIX mode reports `parameter: bad substitution`.

## Tracked future work

- Broader Bash indexed array semantics:
  - associative arrays and declaration builtins
  - array slicing and transformation forms
- Remaining string parameter expansion edge cases:
  - array-wide or element-specific string operations
  - field-producing `${@:offset:length}` and `${*:offset:length}` positional
    slices
  - replacement `&` expansion and any remaining replacement/pattern delimiter
    edge cases not covered by quoted or nested `/` constructs
- Transform flags such as `${parameter@Q}` are intentionally unsupported until
  a concrete compatibility use case justifies their design.

## Implementation rule

New Bash-compatible behavior should:

1. Be gated through `compat.Features.bash()` or another explicit compatibility
   feature.
2. Preserve current POSIX/default-mode behavior, including diagnostics where
   tests already assert them.
3. Include focused Bash-mode tests and, when relevant, default/POSIX rejection
   tests.
4. Update this document when the supported extension surface changes.
