# POSIX negative diagnostics corpus

This corpus records expected Rush behavior for syntax, expansion, redirection, and builtin error cases. It is separate from `test/corpus/posix` because many diagnostics and shell-error consequences are not differential-safe across comparison shells.

Each case has the same files as the POSIX expected-output corpus:

- `script`
- `status`
- `stdout`
- `stderr`

A case may also include an optional `requires` file with one requirement per line. Supported requirements are `os:linux` and `path:/absolute/path`; cases with unmet requirements are skipped so platform-specific diagnostics can live in the corpus without breaking cross-platform validation.

Some cases currently document Rush baseline behavior that intentionally continues after an error. Those cases are useful regression tests and targets for future stricter POSIX error-consequence work.
