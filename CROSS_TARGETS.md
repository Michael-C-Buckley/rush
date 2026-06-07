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
- compile-only `zig test -fno-emit-bin -target ... src/main.zig` for:
  - `x86_64-linux-gnu`
  - `aarch64-linux-gnu`
  - `x86_64-macos`
  - `aarch64-macos`
  - `x86_64-freebsd`
  - `x86_64-openbsd`
  - `x86_64-netbsd`

Foreign target binaries are not run on the Linux development host. These checks are intended to catch accidental target-specific API usage such as Linux-only fd plumbing in code that should also compile for macOS/BSD.
