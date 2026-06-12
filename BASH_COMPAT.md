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
- Rush still treats unresolved negative-subscript failures as expansion errors
  using Rush's existing non-interactive stopping behavior. Bash itself continues
  after some compound-assignment and `unset` bad-subscript diagnostics.

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

## Tracked future work

- Broader Bash indexed array semantics:
  - associative arrays and declaration builtins
  - array slicing and transformation forms
- String parameter expansion extensions:
  - substring `${parameter:offset[:length]}`
  - replacement `${parameter/pattern/repl}`
  - case modification `${parameter^}` / `${parameter,}`
- Indirect and name-prefix parameter expansion:
  - `${!name}`
  - `${!prefix*}` / `${!prefix@}`
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
