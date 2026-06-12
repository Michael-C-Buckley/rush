# rush

Rush is an experimental, POSIX-facing shell with Bash compatibility and
interactive UX improvements under active development. It is early software: the
implementation moves quickly, APIs may change, and the POSIX compliance numbers
are planning evidence rather than certification.

## Current focus

- POSIX shell execution, expansion, redirection, job-control, and builtin
  coverage tracked in [`POSIX_AUDIT.md`](POSIX_AUDIT.md) and
  [`test/compliance/posix-shell.tsv`](test/compliance/posix-shell.tsv).
- Incremental Bash-compatible features tracked separately in
  [`BASH_COMPAT.md`](BASH_COMPAT.md); Rush defaults to POSIX-facing behavior.
- A terminal line editor with parser-aware completions, history search,
  autosuggestions, emacs/vi editing modes, styled diagnostics, prompt hooks, and
  adaptive theme variables.

Rush targets POSIX-like systems first: Linux, macOS, and BSDs. Cross-target
compile coverage is documented in [`CROSS_TARGETS.md`](CROSS_TARGETS.md);
runtime validation still needs to happen on each claimed host.

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

Common build options:

- `-Dsysconfdir=/etc` sets the system configuration directory. The default is
  `<prefix>/etc`.
- `-fsys=sqlite3` links against system SQLite instead of the bundled
  amalgamation.
- `-Dtarget=...` cross-compiles; use `zig build cross-check` for the maintained
  compile-only target set.

## Run

```sh
zig build run
zig build run -- -c 'echo hello'
./zig-out/bin/rush --help
```

CLI forms currently supported:

```text
rush [--login]
rush [-i] [--posix-strict] [set-options] -c SCRIPT [NAME [ARGS...]]
rush [-i] [--posix-strict] [set-options] -s [ARGS...]
rush [-i] [--posix-strict] [set-options] SCRIPT_FILE [ARGS...]
rush complete --debug INPUT
rush complete --debug-json INPUT
rush complete trace INPUT
rush complete trace --json INPUT
rush complete validate [PATH]
rush --help
```

`--posix-strict` enables stricter POSIX syntax diagnostics for non-interactive
execution. There is not currently a user-facing Bash-mode CLI flag; Bash-mode
compatibility is exercised through the implementation's compatibility feature
plumbing and tests.

## Test and validation

```sh
zig build test                         # unit tests
zig build check                        # unit tests plus repo validation checks
zig build fmt                          # Zig formatting check
zig build completion-validate          # shipped .rush completion scripts
zig build completion-manifest-schema   # JSON schema and examples
zig build compliance                   # POSIX compliance report and corpora
zig build cross-check                  # native tests plus compile-only targets
```

The POSIX differential corpus uses `dash` and/or `bash --posix` when they are
available; see [`POSIX_COMPARISON_SHELLS.md`](POSIX_COMPARISON_SHELLS.md).

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
`$HOME/.config/rush/`. The embedded defaults live in
[`share/rush/config.rush`](share/rush/config.rush) and define prompt defaults,
colorized `ls`/`grep`/`diff` helpers, and `ll`/`la` abbreviations that later
config files can override or erase.

More configuration and prompt examples are in
[`website/docs/configuration.html`](website/docs/configuration.html) and
[`website/docs/features.html`](website/docs/features.html).

## Completions

Rush completions are structured rules evaluated against the parsed command
line. Small completions can be written as `.rush` scripts with `complete` and
`completion`; larger generated completions can put static grammar in a JSON
manifest and keep dynamic providers in a companion `.rush` file.

Completion files are loaded lazily for the command being completed from:

```text
$XDG_DATA_HOME/rush/completions/COMMAND.{json,rush}
$HOME/.local/share/rush/completions/COMMAND.{json,rush}
$XDG_DATA_DIRS/rush/completions/COMMAND.{json,rush}
/usr/local/share/rush/completions/COMMAND.{json,rush}
/usr/share/rush/completions/COMMAND.{json,rush}
$XDG_CONFIG_HOME/rush/completions/COMMAND.{json,rush}
$HOME/.config/rush/completions/COMMAND.{json,rush}
```

Installed first-party completion files are placed under
`$prefix/share/rush/completions/`. The repository currently ships a Git
manifest and companion providers at
[`share/rush/completions/git.json`](share/rush/completions/git.json) and
[`share/rush/completions/git.rush`](share/rush/completions/git.rush).

If `COMMAND.json` and `COMMAND.rush` are colocated, the manifest owns the static
rules and the `.rush` file is treated as provider-only companion code, sourced
lazily when a manifest function provider is needed. Manifest version `1` uses
the schema URL `https://rush.horse/completion/schema/v1.schema.json`; the local
schema lives at
[`website/completion/schema/v1.schema.json`](website/completion/schema/v1.schema.json).

### `.rush` completion DSL

The old bare provider form `complete COMMAND --function FUNC` is not supported.
Dynamic providers must declare the semantic context they provide with one of
`--subcommands`, `--options`, `--argument`, or `--option-value`.

```sh
complete git --subcommand commit --description 'record changes'
complete 'git commit' --option --long amend --description 'amend the previous commit'
complete 'git commit' --option --short m --long message --value-name text

__rush_complete_git_branches() {
  git branch --format='%(refname:short)' 2>/dev/null |
    completion candidates --kind plain --description branch
}
complete 'git checkout' --argument --function __rush_complete_git_branches
```

Useful forms:

```text
complete PATTERN --subcommand NAME [--description TEXT]
complete PATTERN --option [--short C] [--long NAME] [--value-name NAME]
                 [--exclusive-group GROUP] [--repeatable]
                 [--terminates-options] [--no-space] [--description TEXT]
complete PATTERN --subcommands --function FUNC
complete PATTERN --options --function FUNC
complete PATTERN --argument --function FUNC [--index N]
complete PATTERN --argument --state NAME [--after WORD]
                 [--after-state NAME] [--repeatable] --function FUNC
complete PATTERN --option-value (--long NAME | --short C) --function FUNC
                 [--list-separator C] [--key-value-separator C]
```

Provider helpers include:

```text
completion candidate VALUE [--display TEXT] [--description TEXT] [--kind KIND]
                           [--suffix TEXT] [--removable-suffix] [--no-space]
completion candidates [--description TEXT] [--kind KIND] [--no-space]  # stdin lines
completion option [--long NAME] [--short C] [--argument NAME]
                  [--repeatable] [--exclusive-group NAME]
                  [--terminates-options] [--description TEXT]
completion files [--prefix TEXT] [--extension EXT]
completion directories [--prefix TEXT] [--append-slash]
completion executables [--prefix TEXT]
completion variables [--prefix TEXT]
```

Provider functions receive `rush_completion_*` variables for the semantic
context, including prefix, command path, position, argument state/index, active
option value, parsed option state, and structured value segment/key data.
Parameterized queries such as `completion option-present --long NAME`,
`completion option-values --long NAME`, and `completion operands` remain
available when a provider needs list data.

Use `rush complete trace INPUT` to debug completion resolution. The text trace
includes the manifest path/version, selected command path, parsed options and
operands, active argument state, provider decisions with candidate counts,
suppressed options, fallback reason, candidate filtering, provider diagnostics,
and the edit Rush would apply. Use `rush complete trace --json INPUT` for the
same manifest trace data in the `manifest` JSON object.

For the full completion reference, see
[`website/docs/completion.html`](website/docs/completion.html). The manifest
design and compatibility notes are in
[`COMPLETION_MANIFEST.md`](COMPLETION_MANIFEST.md) and
[`website/docs/completion-manifest.html`](website/docs/completion-manifest.html).

## License

MIT; see [`LICENSE`](LICENSE).
