# rush

Rush is an experimental shell.

## Structured completion DSL

Rush completion scripts register semantic command rules with the `complete`
builtin. Rules are scoped to a command pattern, so Rush can complete the right
subcommands, options, arguments, and option values for the command position the
user is editing.

Rush is unreleased; completion authors should use only the structured DSL below.
The old bare provider form `complete COMMAND --function FUNC` is intentionally
not supported. Dynamic providers must declare the context they provide with one
of `--subcommands`, `--options`, `--argument`, or `--option-value`.

Completion scripts can be loaded from Rush configuration. Put completion rules
in the interactive config file, or source other `.rush` files from there:

```sh
$XDG_CONFIG_HOME/rush/config.rush
```

If `XDG_CONFIG_HOME` is unset, Rush uses `$HOME/.config/rush/config.rush`.
First-party example completions are installed under
`$prefix/share/rush/completions/`; source the ones you want from `config.rush`.

### Command patterns

The first argument to `complete` is a command pattern. It names the root command
and, optionally, a subcommand path:

```sh
complete git --subcommand commit
complete 'git commit' --option --long amend
complete 'kubectl get pods' --option --long watch
```

Patterns are parsed as shell words when the rule is registered. Quote patterns
that contain spaces. Pattern parsing does not depend on the runtime value of
`IFS`.

### Static rules

Use static rules when the candidates are known without running a provider
function.

```sh
# Subcommands for `git ...`.
complete git --subcommand status --description 'show the working tree status'
complete git --subcommand commit --description 'record changes'

# Options available while completing `git commit ...`.
complete 'git commit' --option --long amend --description 'amend the previous commit'
complete 'git commit' --option --short m --value-name message --description 'commit message'

# Options on the root command can consume values before subcommand analysis.
complete git --option --short C --value-name path --description 'run as if git started in path'
complete git --option --long git-dir --value-name path --description 'path to the repository'

# Mutually exclusive option groups suppress conflicting option candidates.
complete git --option --long json --exclusive-group output --description 'JSON output'
complete git --option --short p --long porcelain --exclusive-group output --description 'porcelain output'
```

`--option` rules require at least one spelling:

- `--long NAME` completes `--NAME`.
- `--short C` completes `-C`.
- `--value-name NAME` marks the option as taking a value. This lets semantic
  analysis treat the next word, or the suffix after `--long=`, as an option
  value.
- `--description TEXT` shows help text in completion menus.
- `--no-space` avoids inserting a trailing space after accepting the option.
- `--repeatable` keeps the option available after it has already appeared;
  non-repeatable options are suppressed after use and repeated uses are reported
  in completion diagnostics.
- `--exclusive-group NAME` hides other options in the same group after one is
  already present and reports conflicting combinations in completion diagnostics.
- `--terminates-options` marks an option that stops later words from being
  parsed as options. A bare `--` always terminates option parsing.

### Dynamic providers

Use dynamic providers when candidates depend on the filesystem, environment, or
the current semantic completion context. A provider is a Rush function that emits
candidates with the `completion` helper builtin.

```sh
__rush_complete_git_subcommands() {
  completion candidate status --kind subcommand --description 'show status'
  completion candidate switch --kind subcommand --description 'switch branches'
}
complete git --subcommands --function __rush_complete_git_subcommands

__rush_complete_git_commit_options() {
  completion option --long amend --description 'amend the previous commit'
  completion option --short m --argument message --description 'commit message'
}
complete 'git commit' --options --function __rush_complete_git_commit_options
```

Dynamic provider registrations are context-scoped:

- `complete PATTERN --subcommands --function FUNC` runs `FUNC` while completing
  subcommands directly under `PATTERN`.
- `complete PATTERN --options --function FUNC` runs `FUNC` while completing
  options for `PATTERN` and its nested subcommand positions.
- `complete PATTERN --argument --function FUNC` runs `FUNC` while completing
  positional arguments at `PATTERN`.
- `complete PATTERN --argument --index N --function FUNC` runs `FUNC` for the
  zero-based semantic argument index `N`, after known options and option values
  are skipped.
- `complete PATTERN --argument --state NAME [--index N] [--after WORD]
  [--after-state NAME] [--repeatable] --function FUNC` names positional states
  for multi-argument flows. Unconditional states without `--index` are assigned
  in registration order; `--repeatable` makes the state cover later arguments.
- `complete PATTERN --option-value --long NAME --function FUNC` runs `FUNC` for
  the value of `--NAME` at `PATTERN`.
- `complete PATTERN --option-value --short C --function FUNC` runs `FUNC` for
  the value of `-C` at `PATTERN`.

Rush runs interactive dynamic providers asynchronously. A provider sees a
snapshot of shell state from when the completion request started: variables,
aliases, functions, and completion rules are available, but mutations made by
the provider are discarded when completion finishes. Filesystem and external
command side effects are not sandboxed, so providers should still be written as
read-only queries. If a newer completion request supersedes an older one, Rush
discards the stale result and asks in-flight external commands to terminate.

### Provider helper builtins

Provider functions can emit candidates directly:

```sh
completion candidate VALUE [--display TEXT] [--description TEXT] [--kind KIND] [--no-space]
completion option [--long NAME] [--short C] [--argument NAME] [--repeatable] [--exclusive-group NAME] [--terminates-options] [--description TEXT]
```

Candidate kinds include `command`, `builtin`, `function`, `file`, `directory`,
`variable`, `option`, `subcommand`, and `plain`.

Providers can also delegate to built-in sources:

```sh
completion files        # filesystem entries
completion directories  # directories only
completion executables  # executable commands from PATH
completion variables    # shell variables
```

For option-value providers, `completion option` updates the active option-value
context when its option spelling matches the option being completed. This keeps
option candidates and option-value candidates consistent when a provider emits
both.

### Completion context queries

Dynamic providers can inspect the semantic context with:

```sh
completion prefix          # text being completed
completion command         # root command, such as `git`
completion command-path    # root plus resolved subcommand path, such as `git commit`
completion argument-index  # zero-based semantic argument index
completion argument-state  # active named argument state, if one matched
completion previous        # previous semantic word
completion position        # command, subcommand, option, argument, or option_value
completion option-name     # active option's declared name during option-value completion
completion option-spelling # active spelling, such as `-C` or `--git-dir`
```

These queries are based on Rush's semantic completion analysis, not simple word
splitting. Registered structured rules let Rush skip option values, understand
nested subcommands, and generate semantic diagnostics and underlines for unknown
commands, subcommands, options, and missing option values.

### Mixed static and dynamic example

This example completes a small `kubectl` slice with static subcommands/options
and dynamic resource names:

```sh
complete kubectl --option --long context --value-name name --description 'kube context'
complete kubectl --subcommand get --description 'display resources'
complete 'kubectl get' --subcommand pods --description 'pod resources'
complete 'kubectl get pods' --option --long watch --description 'watch for changes'

__rush_complete_kubectl_pods() {
  # A real provider could call kubectl here.
  completion candidate frontend --kind plain --description 'frontend pod'
  completion candidate worker --kind plain --description 'worker pod'
}
complete 'kubectl get pods' --argument --function __rush_complete_kubectl_pods

__rush_complete_kubectl_contexts() {
  completion candidate dev --kind plain
  completion candidate prod --kind plain
}
complete kubectl --option-value --long context --function __rush_complete_kubectl_contexts
```
