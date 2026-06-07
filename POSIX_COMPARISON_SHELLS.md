# POSIX Comparison Shells

Rush has two POSIX-oriented corpus workflows:

- `zig build posix-corpus`
  - Runs Rush against spec-derived expected-output cases in `test/corpus/posix/`.
  - Does not require any other shell.
- `zig build corpus`
  - Differentially compares Rush with whatever comparison shells are installed.
  - The harness is intentionally tolerant of missing shells.

## Supported comparison matrix

`scripts/check-system-shell-corpus.sh` checks for these shells:

| Label | Command used | Notes |
| --- | --- | --- |
| `dash` | `dash -c SCRIPT` | Small POSIX `/bin/sh` implementation; excellent baseline. |
| `bash` | `bash -c SCRIPT` | Useful compatibility reference, but not strict POSIX by default. |
| `bash-posix` | `bash --posix -c SCRIPT` | Bash in POSIX mode; useful but still Bash. |
| `yash` | `yash -c SCRIPT` | Strong POSIX conformance reference when available. |
| `busybox-ash` | `busybox ash -c SCRIPT` | BusyBox ash; useful embedded/POSIX-ish reference. |
| `mksh` | `mksh -c SCRIPT` | Not POSIX-pure, but useful for cross-shell behavior checks. |

On a minimal system, only Bash may be installed. That is fine: the differential corpus will report how many comparisons it ran.

## Provisioning helper

Run:

```sh
scripts/provision-posix-shells.sh --check
```

To print detected/missing shells.

Run:

```sh
scripts/provision-posix-shells.sh --install
```

To install optional shells using a supported package manager.

The script currently knows about:

- Arch Linux: `pacman`
- Debian/Ubuntu: `apt-get`
- Alpine: `apk`
- Fedora/RHEL-ish: `dnf`
- macOS/Homebrew: `brew`

Package availability varies by platform. The helper is best-effort; missing packages should not block Rush development.

## Recommended local setup

For Linux development, the most valuable matrix is:

```sh
dash bash yash busybox mksh
```

After installing, run:

```sh
zig build corpus --summary all
zig build posix-corpus --summary all
```

Expected differential output should look like:

```text
system shell corpus passed (N cases, M comparisons across: dash bash bash-posix yash busybox-ash mksh)
```

The exact shell list depends on what is installed.

## Adding new comparison shells

When adding a shell to `scripts/check-system-shell-corpus.sh`:

1. Keep it optional.
2. Give it a stable label.
3. Prefer POSIX mode where available.
4. Avoid treating a shell disagreement as Rush truth; differential cases should cover behavior Rush intentionally supports.
5. Put spec-derived expected behavior in `test/corpus/posix/` instead of relying only on differential tests.
