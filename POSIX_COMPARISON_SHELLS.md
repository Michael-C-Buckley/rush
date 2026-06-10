# POSIX Comparison Shells

Rush has two POSIX-oriented corpus workflows:

- `zig build posix-corpus`
  - Runs Rush against spec-derived expected-output cases in `test/corpus/posix/`.
  - Does not require any other shell.
- `zig build corpus`
  - Differentially compares Rush with the comparison shells installed on the system.
  - The harness is intentionally tolerant of missing shells.

## Comparison matrix

`scripts/check-system-shell-corpus.sh` checks for these shells:

| Label | Command used | Notes |
| --- | --- | --- |
| `dash` | `dash -c SCRIPT` | Small POSIX `/bin/sh` implementation; the strictest single oracle. |
| `bash-posix` | `bash --posix -c SCRIPT` | Bash in POSIX mode; useful second opinion, but still Bash. |

Both shells ship preinstalled on macOS and virtually every Linux
distribution, so no provisioning is needed. The matrix is intentionally
small: a wider matrix (yash, busybox ash, mksh) mostly re-confirmed the
same results while multiplying runtime and accumulating per-shell skip
lists for legitimate divergences.

Known divergences where the system bash disagrees with Rush and dash are
tracked as tasks rather than skip lists; see the corpus failure output
for the current set.

## Adding new comparison shells

When adding a shell to `scripts/check-system-shell-corpus.sh`:

1. Keep it optional.
2. Give it a stable label.
3. Prefer POSIX mode where available.
4. Avoid treating a shell disagreement as Rush truth; differential cases should cover behavior Rush intentionally supports.
5. Put spec-derived expected behavior in `test/corpus/posix/` instead of relying only on differential tests.
