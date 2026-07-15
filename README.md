# rush

[![CI](https://github.com/rockorager/rush/actions/workflows/ci.yml/badge.svg)](https://github.com/rockorager/rush/actions/workflows/ci.yml)

Rush is an experimental, POSIX-facing shell with Bash compatibility and
interactive UX improvements under active development. It is early software: the
implementation moves quickly, APIs may change, and POSIX compatibility is a
work in progress rather than a certification claim.

## Current focus

- POSIX shell execution, expansion, redirection, job-control, and builtins.
- Incremental Bash-compatible features; Rush defaults to POSIX-facing behavior.
- A terminal line editor with history search, emacs/vi editing modes, styled
  diagnostics, and a rebuilt interactive shell on top of `shell/` and
  `runtime/`.

Rush targets POSIX-like systems first: Linux, macOS, and BSDs.

## Build and install

Rush currently requires Zig 0.16. The repository includes `mise.toml` for
`mise` users, and Zig fetches the declared dependencies from `build.zig.zon`.
SQLite is built from the bundled amalgamation by default; packagers can opt into
system SQLite with `-fsys=sqlite3`.

```sh
git clone https://github.com/rockorager/rush
cd rush
zig build
zig build install --prefix "$HOME/.local" -Doptimize=ReleaseSafe
```

Arch Linux users can install the latest development revision from the AUR:

```sh
git clone https://aur.archlinux.org/rush-shell-git.git
cd rush-shell-git
makepkg -si
```

The package is named `rush-shell-git` to distinguish it from the existing GNU
Restricted User Shell package, which also installs `/usr/bin/rush`. A future
tagged-release package can use the corresponding `rush-shell` name.

Common build options:

- `-Dsysconfdir=/etc` sets the system configuration directory. The default is
  `<prefix>/etc`.
- `-Dregister-shell=false` skips adding the installed executable to
  `/etc/shells`; package builds should use this option.
- `-fsys=sqlite3` links against system SQLite instead of the bundled
  amalgamation.
- `-Dtarget=...` cross-compiles.

The install includes `rush(1)` for command usage and `rush(5)` for interactive
configuration and prompts. Run `man rush` or `man 5 rush` after installation.

## Run

```sh
zig build run
zig build run -- -c 'echo hello'
./zig-out/bin/rush --help
```

CLI forms currently supported:

```text
rush [--login] [--posix] [-i] [-u] [-x]
rush [--posix] [-i] [-u] [-x] -c SCRIPT [NAME [ARGS...]]
rush [--posix] [-i] [-u] [-x] [--] SCRIPT_FILE [ARGS...]
rush --help
rush --version
```

`--posix` selects POSIX mode with stricter syntax diagnostics for
non-interactive execution. There is not currently a user-facing Bash-mode CLI
flag; Bash-mode compatibility is exercised through the implementation's
compatibility feature plumbing and tests.

## Test and validation

```sh
zig fmt --check build.zig build.zig.zon src tests fuzz
zig build compile-check
zig build lint
zig build test
zig build conformance
```

GitHub Actions runs these checks for every pull request and push to `main`.

## Configuration

Interactive startup sources Rush scripts in this order:

```text
embedded default configuration
$ENV
$sysconfdir/rush/profile.rush      (login shells only)
$XDG_CONFIG_HOME/rush/profile.rush (login shells only)
$sysconfdir/rush/config.rush
$XDG_CONFIG_HOME/rush/config.rush
```

If `XDG_CONFIG_HOME` is unset, user files fall back to
`$HOME/.config/rush/`. The embedded defaults come from
[`share/rush/config.rush`](share/rush/config.rush) and define prompt defaults,
style defaults, and `ll`/`la` abbreviations that later config files can
override or erase. Rush-mode shells also autoload functions from
`rush/functions` search directories when a matching function name is used;
shipped defaults include colorized `ls`/`grep`/`diff` helpers, `path_*` PATH
helpers, and opt-in project-environment hooks there.

More configuration and prompt examples are in
[`website/docs/configuration.html`](website/docs/configuration.html) and
[`website/docs/features.html`](website/docs/features.html).

## License

MIT; see [`LICENSE`](LICENSE).
