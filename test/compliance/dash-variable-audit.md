# Dash shell-maintained variable audit

This audit records permissively licensed dash behavior for shell-maintained
variables that Rush should consider for POSIX and interactive compatibility.
It is based on the upstream `hvdijk/dash` repository, version `0.6.0`, whose
Almquist/Berkeley-derived source is 3-clause BSD licensed (`COPYING`). Do not
use GPL shell sources for these implementation decisions.

## Dash variable architecture

Dash stores variables in a hash table of `struct var` nodes in `src/var.c` and
`src/var.h`. A static `varinit[]` table pre-allocates shell-maintained entries
with flags such as `VEXPORT`, `VREADONLY`, `VSTRFIXED`, `VTEXTFIXED`, `VUNSET`,
`VLATEFUNC`, and `VUSER1`. Some variables also have change callbacks.

Startup initialization in `src/var.c` imports environment variables and then
sets shell-maintained defaults. The important ordering is:

1. initialize the `varinit[]` table;
2. import valid `NAME=VALUE` entries from the environment as exported;
3. reset `IFS` to the default `" \t\n"`;
4. reset `OPTIND` to `1`;
5. set `PPID` from `getppid()`;
6. initialize and export `PWD` from a validated logical directory or `getcwd()`.

## POSIX-required or POSIX-facing variables

| variable | dash source reference | dash behavior | Rush recommendation |
| --- | --- | --- | --- |
| `IFS` | `src/var.c` `varinit[VIFS]`, startup `setvareq(defifsvar, VTEXTFIXED)`; `src/expand.c` field splitting | Default is space, tab, newline; dash resets it after environment import. | Ensure Rush initializes `IFS` explicitly instead of inheriting unsafe environment values. Current expansion/read code has a fallback default, but startup state should be explicit. |
| `PWD` | `src/cd.c` `getpwd()` and `setpwd()`, `src/var.c` startup `setpwd(getpwd(0), 0)` | Validates inherited `PWD` against `.` by device/inode; falls back to `getcwd()`; updates and exports on `cd`. | Initialize and export `PWD` at shell startup, validate inherited `PWD`, and keep current `cd` updates. |
| `OLDPWD` | `src/cd.c` `setpwd(val, setold)` and `cdcmd()` | Set/exported on successful `cd`; used by `cd -`; not initialized at startup. | Add `cd -`/`OLDPWD` behavior if absent and keep OLDPWD exported once set. |
| `PPID` | `src/var.c` startup formatting from `getppid()` | Set once at startup, not exported by default. | Add startup `PPID`; make readonly if Rush chooses stricter POSIX behavior. |
| `LINENO` | `src/var.c` `varinit[VLINENO]` and lazy `lookupvar()` formatting; evaluator updates node line numbers | Lazily computed when expanded; based on parser/evaluator line tracking. | Implement after Rush has reliable source-line tracking through parser/evaluator nodes. |
| `PS1`/`PS2` | `src/var.c` `varinit[VPS1]`, `varinit[VPS2]`; `src/input.c` prompt selection | Defaults are `"$ "` and `"> "`; used literally, not bash-style prompt expansion; not exported. | For POSIX interactive compatibility, support literal `PS1`/`PS2` defaults and user overrides. |
| `PS4` | `src/var.c` `varinit[VPS4]`; `src/eval.c` xtrace output | Default `"+ "`; used for `set -x` tracing. | Implement with xtrace/verbose audit work. |
| `OPTIND` | `src/var.c` `varinit[VOPTIND]`; `src/options.c` `getoptsreset()` | Default `1`; user assignment resets internal getopts cursor. | Rush already has getopts state; audit reset semantics when users assign `OPTIND`. |
| `OPTARG` | `src/options.c` `getopts()` | Set/unset dynamically during `getopts`; not exported by default. | Rush already sets/unsets `OPTARG`; keep coverage for missing/invalid option classes. |
| `PATH` | `src/var.c` `varinit[VPATH]`, `changepath` callback | Default path, exported, command hash invalidated on changes. | Rush should keep PATH lookup behavior and invalidate any command cache if added. |
| `HOME` | `src/cd.c` no-argument `cd`; `src/expand.c` tilde expansion | Inherited/user variable used by `cd` and tilde expansion. | Current `cd`/tilde work should keep HOME behavior covered. |
| `ENV` | `src/main.c` interactive startup file loading | Sourced for interactive, non-privileged shells. | Add interactive `ENV` loading if Rush targets POSIX interactive startup compatibility. |
| `CDPATH` | `src/cd.c` `cdcmd()` | Search path for relative `cd` operands. | Add with `cd`/`pwd` POSIX utility hardening. |

## Common shell behavior or lower-priority variables

| variable | dash source reference | dash behavior | Rush recommendation |
| --- | --- | --- | --- |
| `_` | `src/eval.c` `evalcommand()` | Updated only in interactive top-level commands; dash source notes it is mostly for line-editing history behavior; not exported. | Skip initially. Not POSIX-required and low value for Rush. |
| `SHLVL` | absent from dash source | Dash does not implement it. | Optional low-priority compatibility feature; not needed for POSIX compliance. |
| `LINES`/`COLUMNS` | absent from dash source | Dash does not maintain terminal dimensions. | Keep in the terminal/editor layer if needed; do not prioritize in the shell engine. |
| `MAIL`/`MAILPATH` | `src/var.c` `varinit[VMAIL]`, `varinit[VMPATH]`, `changemail` | Historical interactive mail checks. | Skip unless POSIX test coverage demands it. |
| `FPATH` | `src/var.c` `varinit[VFPATH]` | ksh-style autoload path. | Skip. |
| `LC_*`, `LANG` | `src/var.c` `WITH_LOCALE` entries and `changelocale()` | Optional locale callbacks update C locale categories. | Defer until Rush supports locale-aware collation/multibyte behavior. |
| `TERM`/`HISTSIZE` | `src/var.c` non-`SMALL` entries | Interactive terminal/history support. | Inherit `TERM`; implement `HISTSIZE` with history support if needed. |

## Follow-up recommendations

1. Add startup shell-maintained variable initialization for `IFS`, `PWD`, and
   `PPID`; validate inherited `PWD` before trusting it and export `PWD`.
2. Deepen `cd`/`pwd` support with `OLDPWD`, `cd -`, `CDPATH`, and export
   behavior.
3. Add interactive `PS1`/`PS2` literal prompt variables and `ENV` startup file
   loading for POSIX interactive compatibility.
4. Add `LINENO` only after parser/evaluator line tracking can provide stable
   source line numbers through scripts, sourced files, functions, and command
   substitutions.
5. Defer or skip `SHLVL`, `_`, `LINES`, `COLUMNS`, `MAIL`, `MAILPATH`, `FPATH`,
   locale callbacks, and history variables unless separate product or POSIX
   evidence makes them necessary.
