# Cross-target checks

Rush targets POSIX-like systems first: Linux, macOS, and BSDs.

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
