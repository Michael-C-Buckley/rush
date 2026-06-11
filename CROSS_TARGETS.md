# Cross-target checks

Rush targets POSIX-like systems first: Linux, macOS, and BSDs.

## Compile-only portability checks

Run the native test suite plus compile-only checks for representative targets:

```sh
zig build cross-check
```

Equivalent script:

```sh
scripts/check-cross-targets.sh
```

The script runs:

- native `zig build test --summary all` on the host
- compile-only `zig build compile-test -Dtarget=... --summary none` for:
  - `x86_64-linux-gnu`
  - `aarch64-linux-gnu`
  - `x86_64-macos`
  - `aarch64-macos`
  - `x86_64-freebsd`
  - `x86_64-openbsd`
  - `x86_64-netbsd`

Foreign target binaries are not run by this local check. These checks are intended to catch accidental target-specific API usage, such as Linux-only fd plumbing in code that should also compile for macOS/BSD. Runtime validation on actual Linux and BSD hosts remains separate follow-up work and is not part of the `portability-cross-target` compile-coverage compliance row.

## Native runtime portability checks

Compile coverage does not prove runtime behavior on another kernel or libc. To collect runtime portability evidence, run the native suite on each real host, VM, or jail being claimed:

```sh
scripts/check-runtime-portability.sh
```

The script records the host OS, machine, and Zig version, then runs the compliance manifest check, POSIX expected-output corpus, POSIX negative corpus, system-shell differential corpus, and full native `zig build test --summary none` suite. The system-shell corpus currently requires `dash` or `bash` for POSIX-mode comparison; install one of those shells on BSD hosts before treating the run as complete.

Track runtime evidence separately from compile-only coverage. For each run, record the host OS/version (`uname -a`), architecture (`uname -m`), `zig version`, comparison shells available, skipped platform-gated cases, command output, and any failures in Tend or release notes.

Current runtime evidence matrix:

| runtime host | command | status |
| --- | --- | --- |
| Linux x86_64 | `scripts/check-runtime-portability.sh` | external run required; not validated from macOS |
| Linux aarch64 | `scripts/check-runtime-portability.sh` | external run required; not validated from macOS |
| FreeBSD x86_64 | `scripts/check-runtime-portability.sh` | external run required; not validated from macOS |
| OpenBSD x86_64 | `scripts/check-runtime-portability.sh` | external run required; not validated from macOS |
| NetBSD x86_64 | `scripts/check-runtime-portability.sh` | external run required; not validated from macOS |
