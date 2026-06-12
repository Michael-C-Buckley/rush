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
  - arithmetic subscript expressions such as `name[i + 1]=word`
  - subscript expressions containing nested parameter, command, or arithmetic substitutions
  - whitespace inside assignment subscripts, such as `name[ i + 1 ]=word`
  - whitespace-only assignment subscripts as index `0`, such as `name[   ]=word`
  - `${name[index]}` expansion against Rush's array runtime
- `read -d delimiter` delimiter selection:
  - separate delimiter operand, e.g. `read -d : name`
  - attached/grouped option spelling, e.g. `read -d: name` or `read -rd: name`
  - empty delimiter operand as NUL

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
  - compound assignment
  - whole-array expansion
  - array-specific parameter operations
  - negative relative indices
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
