# Rush completion manifest design

This document designs the first version of Rush's structured completion
manifest format. It is the design artifact for Tend task #580.

## Goal

Rush completions should have two authoring layers:

```text
share/rush/completions/git.json  # declarative completion grammar
share/rush/completions/git.rush  # dynamic provider functions
```

The manifest describes the static and semantic shape of a command: command
paths, subcommands, options, option values, option groups, argument states,
value grammars, and provider references. The `.rush` companion file defines the
imperative providers that must query the filesystem, environment, or external
commands.

This keeps the common case agent-friendly and machine-validatable while
preserving Rush functions for dynamic behavior.

## Non-goals for v1

- Do not port all existing first-party completions to manifests.
- Do not import zsh, fish, bash, Fig, or framework-generated completions.
- Do not embed shell snippets or arbitrary expression strings in JSON.
- Do not build a general constraint solver for every possible CLI grammar.
- Do not require manifests for small human-authored completions; `.rush`
  declarations remain useful.

## Relationship to existing Rush completions

Current `.rush` completion files are fish-like: readable `complete` declarations
plus dynamic shell functions. The target engine semantics are closer to zsh:
parsed options, option occurrence, option relationships, positional states,
value grammars, and structured provider context.

The manifest format should become a structured input to the same completion rule
graph used by current `.rush` declarations:

```text
.rush declarations ─┐
                    ├─> completion rule graph / IR ─> runtime completion
.json manifests  ───┘
```

The manifest is not a JSON encoding of zsh's `_arguments` language. It directly
models the completion grammar Rush needs.

## Versioning

Use both `$schema` and `manifestVersion`:

```json
{
  "$schema": "https://rush.horse/completion/schema/v1.schema.json",
  "manifestVersion": 1,
  "command": {
    "name": "git"
  }
}
```

- `$schema` is advisory metadata for editors, validators, and documentation.
- `manifestVersion` is Rush runtime semantic version dispatch.

Rush should dispatch on `manifestVersion`, not the schema URL. Users may vendor
schemas locally or generated manifests may omit `$schema`. If `$schema` appears
to reference a different Rush completion schema version than `manifestVersion`,
Rush should report a warning or error.

Use JSON Schema draft 2020-12 for schema documents. The v1 schema id should be:

```text
https://rush.horse/completion/schema/v1.schema.json
```

## File loading model

For `git`, the loader should discover and combine:

```text
share/rush/completions/git.json
share/rush/completions/git.rush
```

Loading should happen in phases:

1. Parse `git.json`.
2. Validate shape against `completion/schema/v1.schema.json` when schema validation is
   available.
3. Run Rush semantic validation.
4. Compile the manifest into completion rules / IR.
5. Register provider references.
6. Source `git.rush` lazily when a referenced Rush function provider is first
   needed.

Built-in providers do not require a companion `.rush` file.

The v1 implementation sources the companion `.rush` file lazily when a manifest
function provider first needs a referenced Rush function. Treat the companion as
provider-only code: keep static declarations in the JSON manifest, and define
only the Rush functions referenced by manifest providers in the `.rush` file.
Static `complete` declarations in a manifest companion are ignored while the
companion is loaded as provider code. Missing provider IDs are reported by
manifest semantic validation; missing Rush functions are reported as provider
diagnostics when completion tries to run the provider.

The loader should support `.rush`-only completions and manifest-backed
completions side by side. If both `git.json` and `git.rush` exist, `git.rush`
should be treated as the provider companion, not as a second source of duplicate
static declarations, unless a later fragment/layering design explicitly allows
that.

## Platforms and installed variants

Some commands have different option grammars on different operating systems or
for different installed implementations. The manifest supports the zsh-style
split between OS gates and one lazy runtime variant probe:

```json
{
  "manifestVersion": 1,
  "command": {
    "name": "ls",
    "platforms": ["darwin", "linux", "freebsd", "openbsd", "netbsd", "dragonfly"],
    "options": [ { "long": "help" } ],
    "variantProbe": {
      "args": ["--version"],
      "matches": {
        "gnu": "GNU coreutils",
        "unix": ""
      }
    },
    "variants": {
      "gnu": {
        "options": [ { "long": "color" } ]
      },
      "unix": {
        "options": [
          { "short": "G" },
          { "short": "@", "platforms": ["darwin"] }
        ]
      }
    }
  }
}
```

- `platforms` is a fixed enum: `darwin`, `linux`, `freebsd`, `openbsd`,
  `netbsd`, `dragonfly`, `windows`, `wasi`, and `haiku`. Unknown IDs are
  validation errors. A command-level gate is evaluated when the manifest loads;
  if the current platform is not listed, no rules from that manifest register.
- Option-level `platforms` may be used inside a variant for a platform-specific
  flag within a broader installed variant (for example BSD/Unix `ls -@` on
  Darwin only).
- `variantProbe.args` is appended to the command name and run lazily on the
  first completion for that command. The probe is cached for the shell session
  and is not run at manifest load.
- `variantProbe.matches` is ordered. A non-empty pattern matches the combined
  stdout/stderr probe output. Plain strings are substring matches; patterns that
  contain `*` or `?` are glob matches against the whole output. Only the final
  match entry may use an empty string, which is the fallback variant.
- Rush skips the probe when a Rush function or shell builtin shadows the command
  name; in that case only the base manifest grammar is active. This matches the
  zsh `_pick_variant -b` boundary: variants describe external command
  implementations, not shell functions or builtins.

Merge semantics are append-only: Rush compiles the base command definition plus
the selected variant overlay. Variant `options`, `optionGroups`, `arguments`,
`subcommands`, `dynamicSubcommands`, `dynamicOptions`, and `providers` append to
the base command at the same command path. Duplicate option spellings in the
effective base+variant scope are semantic validation errors; manifests should
not rely on variant overlays replacing a base option.

## Validation layers

JSON Schema validates shape:

- required top-level fields
- field types
- enum values
- unknown fields rejected with `additionalProperties: false`
- short option spelling is one character
- long option names are syntactically valid
- provider objects have the expected shape

Rush semantic validation checks completion graph correctness:

- provider IDs resolve in lexical/provider scope
- referenced Rush provider functions exist in the companion file, or unresolved
  functions are reported before runtime if lazy validation can inspect them
- duplicate option spellings are rejected in an effective command scope
- duplicate subcommand names and aliases are rejected in a command scope
- `exclusiveGroup` references point to defined groups or are consistently
  auto-defined by policy
- argument states are reachable
- argument state transitions are not ambiguous under the supported condition
  model
- inherited parent options are valid in nested command contexts
- provider context requirements can be satisfied by the active state

## Manifest shape

A v1 manifest has this conceptual shape:

```ts
type Manifest = {
  $schema?: string
  manifestVersion: 1
  command: Command
}

type Command = {
  name: string | string[]
  aliases?: string[]
  description?: string
  hidden?: boolean
  deprecated?: boolean | string
  platforms?: Platform[]
  variantProbe?: VariantProbe
  variants?: Record<string, CommandVariant>
  providers?: Record<string, Provider>
  options?: Option[]
  optionGroups?: OptionGroup[]
  arguments?: ArgumentModel
  subcommands?: Command[]
  dynamicSubcommands?: ProviderRef[]
  dynamicOptions?: ProviderRef[]
}

type Option = {
  short?: string
  long?: string
  aliases?: string[]
  description?: string
  platforms?: Platform[]
  value?: Value | Value[]
  repeatable?: boolean
  exclusiveGroup?: string
  inherit?: boolean
  requires?: string[]
  terminatesOptions?: boolean
  hidden?: boolean
  deprecated?: boolean | string
}

type Platform = "darwin" | "linux" | "freebsd" | "openbsd" | "netbsd" | "dragonfly" | "windows" | "wasi" | "haiku"

type VariantProbe = {
  args: string[]
  matches: Record<string, string>
}

type CommandVariant = Partial<Pick<Command,
  "platforms" | "providers" | "options" | "optionGroups" | "arguments" |
  "subcommands" | "dynamicSubcommands" | "dynamicOptions"
>>

type Value = {
  name?: string
  required?: boolean
  style?: "detached" | "attached" | "attached-or-detached" | "equals" | "optional"
  provider?: ProviderRef
  grammar?: ValueGrammar
  description?: string
}

type ArgumentModel = {
  terminator?: string
  states: ArgumentState[]
}

type ArgumentState = {
  name: string
  index?: number
  repeatable?: boolean
  rest?: "command-line"
  provider?: ProviderRef
  grammar?: ValueGrammar
  description?: string
  when?: Condition
  after?: Condition
  until?: Condition
}

type Provider =
  | { function: string, description?: string, lazy?: boolean }
  | { builtin: "files" | "directories" | "executables" | "variables", description?: string }
  | { values: EnumValue[], description?: string }

type ProviderRef = string | Provider

type EnumValue =
  | string
  | { value: string, description?: string, display?: string,
      suffix?: string, removableSuffix?: boolean, noSpace?: boolean }
```

The initial implementation may omit `dynamicSubcommands`, `dynamicOptions`,
`requires`, `deprecated`, complex `Condition`, and complex `ValueGrammar` fields
until the corresponding engine work exists. They are included here to show the
intended IR direction.

### Names and aliases

`command.name` can be a string or array. If it is an array, the first name is
the canonical display name and later names are aliases. `aliases` is available
when separating canonical name from aliases is clearer.

Options have `short` and/or `long`. Long names are stored without `--`; short
names are stored without `-`.

Completion parsing recognizes POSIX-style clustered short options by default for
declared one-byte short spellings. A completed token such as `-abc` is treated
as `-a -b -c` only when every character resolves in the effective command scope;
otherwise the whole token remains unrecognized. A declared whole-token spelling
always wins, so an option declared as `{ "short": "iname" }` is parsed as
`-iname` rather than as `-i -n -a -m -e`. Short options that take values end a
cluster and consume the rest of the token, or the next word when no rest is
attached. This behavior is engine-owned and has no manifest v1 knob; add an
opt-out only if real command data shows default clustering is harmful.

Parent options are inherited into subcommand contexts by default. Set
`"inherit": false` for options that are only valid before selecting a
subcommand, such as Git's global `-C` and `-c` options, so subcommands may reuse
the same short spelling for local meanings.

An option value may be a single value object or an ordered array of value
objects. Arrays describe options that consume multiple following words, such as
zsh's `-o:arg1:act1:arg2:act2` shape. Each value object may name its own
provider and grammar:

```json
{
  "long": "mode",
  "value": [
    { "name": "output", "provider": "xrandr.outputs" },
    { "name": "mode", "provider": "xrandr.modes" }
  ]
}
```

Only the first value may use attached or equals-style spellings; later values
are always detached words. Optional values (`"required": false`) are valid only
as a trailing run so a required value never follows an optional value. During
operand indexing, Rush skips every consumed option value, so operands after a
multi-value option keep the same argument indexes they would have without the
option occurrence.

### Option groups

Option groups model zsh-like exclusion sets declaratively:

```json
{
  "optionGroups": [
    { "name": "diff-source", "exclusive": true }
  ],
  "options": [
    { "long": "cached", "exclusiveGroup": "diff-source" },
    { "long": "staged", "exclusiveGroup": "diff-source" },
    { "long": "no-index", "exclusiveGroup": "diff-source" }
  ]
}
```

For v1, only exclusive groups are required. `requires`/`implies` can wait unless
implementation falls out naturally.

### Argument states

Argument states model positional operands after option parsing and option-value
skipping. Simple fixed-position cases use `index`:

```json
{
  "arguments": {
    "states": [
      { "name": "remote", "index": 0, "provider": "git.remotes" },
      { "name": "url", "index": 1, "provider": "git.remoteUrlTemplates" }
    ]
  }
}
```

Repeatable trailing operands use `repeatable`:

```json
{
  "arguments": {
    "states": [
      { "name": "pathspec", "repeatable": true, "provider": "git.changedPaths" }
    ]
  }
}
```

Precommand wrappers whose trailing operands are a fresh shell command line use a
terminal rest state:

```json
{
  "arguments": {
    "states": [
      { "name": "command", "rest": "command-line" }
    ]
  }
}
```

`rest: "command-line"` is terminal and implicitly repeatable: it must be the
final state and must not also set `repeatable`, `provider`, or `grammar`. When
completion reaches the state, Rush shifts the remaining operands so the first
rest operand is word 0 and re-enters normal command completion. That means word
0 completes aliases/functions/builtins/executables, later words use the nested
command's manifest or `.rush` rules, and nested wrappers such as `sudo env git
...` work recursively up to the engine depth limit. Leading `VAR=value` words
inside the shifted command line are skipped by the normal shell command parser;
there is no separate manifest flag for env-style assignments.

Git-style ambiguous ref/path cases may use simple conditions. Keep conditions
structured rather than expression strings:

```json
{
  "arguments": {
    "terminator": "--",
    "states": [
      {
        "name": "rev-or-path",
        "repeatable": true,
        "provider": "git.diffRefsAndPaths",
        "until": { "terminatorSeen": true }
      },
      {
        "name": "pathspec",
        "repeatable": true,
        "provider": "git.diffPaths",
        "after": { "terminatorSeen": true }
      }
    ]
  }
}
```

Argument-state conditions can also branch on a parsed option value with
`optionValue`. The value is an object with exactly one option selector mapped to
either one string or an array of strings. The condition is true when any parsed
occurrence of that option has a value exactly equal to one of the listed
literals. Missing options and valueless occurrences are false; repeatable
options use any-match semantics. Equality is the only supported comparison — use
a provider when a branch needs glob, pattern, or expression logic.

```json
{
  "options": [
    {
      "long": "format",
      "value": {
        "name": "format",
        "grammar": { "kind": "enum", "values": ["json", "table"] }
      }
    }
  ],
  "arguments": {
    "states": [
      {
        "name": "json-filter",
        "provider": "tool.jsonFilters",
        "when": { "optionValue": { "--format": "json" } }
      },
      {
        "name": "table-column",
        "provider": "tool.tableColumns",
        "when": { "optionValue": { "--format": ["table"] } }
      }
    ]
  }
}
```

`optionValue` selectors must resolve to value-taking options in the effective
scope. If the selected option value is constrained by enum grammar or by a
static enum provider, every compared literal must be a member of that enum.

If the state logic becomes too complex, the manifest should select a provider
and the provider should branch using parsed completion context queries.

### Value grammars

Value grammars describe replacement spans and value segment context. They can be
introduced incrementally.

Likely grammar kinds:

```json
{ "kind": "enum", "values": ["always", "auto", "never"] }
```

```json
{ "kind": "list", "separator": ",", "item": { "provider": "docker.capabilities" } }
```

```json
{
  "kind": "keyValue",
  "separator": "=",
  "key": { "provider": "config.keys" },
  "value": { "provider": "config.valuesForKey" }
}
```

V1 can start with enum/path/string and defer list/keyValue until the engine can
compute segment replacement spans.

## Provider references

Providers should be named when reused:

```json
{
  "providers": {
    "git.branches": {
      "function": "__rush_complete_git_branches",
      "description": "local branches"
    },
    "builtin.directories": { "builtin": "directories" }
  }
}
```

A value or argument state can reference providers by ID:

```json
{ "name": "branch", "provider": "git.branches" }
```

Inline provider objects are allowed for one-off built-ins, but not for shell
snippets:

```json
{ "provider": { "builtin": "files" } }
```

Do not embed shell in JSON. Dynamic behavior belongs in `.rush` functions.

Builtin providers have fixed v1 behavior and do not accept provider `options`:
`files` completes paths, `directories` completes directory paths with trailing
slashes and no inserted space, `executables` searches `PATH`, and `variables`
uses shell variables. Add a Rush function provider when a completion needs
filtering or behavior beyond those fixed builtins.

Static enum providers keep small, fixed option-value or argument candidate sets
in the manifest instead of a companion Rush function:

```json
{
  "providers": {
    "git.colorModes": { "values": ["always", "auto", "never"] },
    "git.cleanupModes": {
      "values": [
        { "value": "strip", "description": "strip leading/trailing empty lines, comments, and collapse empties" },
        { "value": "whitespace", "description": "strip leading/trailing empty lines" },
        "verbatim"
      ]
    }
  }
}
```

Each value emits a plain candidate. Object entries may set a display label,
description, `suffix`, `removableSuffix`, and `noSpace` for prefix-like values
such as `format:`. Static enum providers are lexically scoped and may be
referenced anywhere a provider ID is accepted; they are intended for finite
enum-like values, not dynamic repository or filesystem data. When a list value
grammar completes an item, Rush automatically applies the list separator as a
removable suffix so the next item can be completed immediately; typing the
separator keeps it, while typing a space or accepting the line removes it first.

## Provider context API dependency

Manifest-backed providers need access to the parsed state selected from the
manifest. Related engine/provider tasks should expose context queries like:

```sh
completion has-option --cached --staged
completion option-value --source
completion terminator-seen
completion operand-index
completion operand 0
completion argument-state
completion argument-state-value treeish
```

Raw word/span queries may still be necessary for refspecs, pathspecs, and value
segments, but structured queries should be preferred.

## Git slice example

`share/rush/completions/git.json`:

```json
{
  "$schema": "https://rush.horse/completion/schema/v1.schema.json",
  "manifestVersion": 1,
  "command": {
    "name": "git",
    "description": "the stupid content tracker",
    "providers": {
      "git.authors": { "function": "__rush_complete_git_authors" },
      "git.refs": { "function": "__rush_complete_git_refs" },
      "git.diffPaths": { "function": "__rush_complete_git_diff_paths" },
      "git.changedPaths": { "function": "__rush_complete_git_changed_paths" },
      "builtin.directories": { "builtin": "directories" }
    },
    "options": [
      {
        "short": "C",
        "value": { "name": "path", "provider": "builtin.directories" },
        "description": "run as if git started in path"
      },
      { "long": "help", "description": "show help" }
    ],
    "subcommands": [
      {
        "name": "commit",
        "description": "record changes to the repository",
        "options": [
          { "short": "a", "long": "all", "description": "stage tracked files before committing" },
          {
            "short": "m",
            "long": "message",
            "value": { "name": "message" },
            "description": "use the given commit message"
          },
          {
            "long": "author",
            "value": { "name": "author", "provider": "git.authors" },
            "description": "override commit author"
          }
        ],
        "arguments": {
          "states": [
            { "name": "pathspec", "repeatable": true, "provider": "git.changedPaths" }
          ]
        }
      },
      {
        "name": "diff",
        "description": "show changes",
        "optionGroups": [
          { "name": "diff-source", "exclusive": true }
        ],
        "options": [
          { "long": "cached", "exclusiveGroup": "diff-source", "description": "compare staged changes" },
          { "long": "staged", "exclusiveGroup": "diff-source", "description": "compare staged changes" },
          { "long": "no-index", "exclusiveGroup": "diff-source", "description": "compare two paths outside a working tree" }
        ],
        "arguments": {
          "terminator": "--",
          "states": [
            {
              "name": "rev-or-path",
              "repeatable": true,
              "provider": "git.refs",
              "until": { "terminatorSeen": true }
            },
            {
              "name": "pathspec",
              "repeatable": true,
              "provider": "git.diffPaths",
              "after": { "terminatorSeen": true }
            }
          ]
        }
      }
    ]
  }
}
```

`share/rush/completions/git.rush`:

```sh
__rush_complete_git_refs() {
  git branch --format='%(refname:short)' 2>/dev/null |
    while read ref; do
      test -n "$ref" && completion candidate "$ref" --kind plain --description branch
    done
  git tag --list 2>/dev/null |
    while read tag; do
      test -n "$tag" && completion candidate "$tag" --kind plain --description tag
    done
}

__rush_complete_git_authors() {
  git log --format='%aN <%aE>' --all 2>/dev/null |
    sort -u |
    while read author; do
      test -n "$author" && completion candidate "$author" --kind plain
    done
}

__rush_complete_git_changed_paths() {
  git status --porcelain=v1 -z 2>/dev/null |
    tr '\0' '\n' |
    sed 's/^...//' |
    while read path; do
      test -n "$path" && completion candidate "$path" --kind file
    done
}

__rush_complete_git_diff_paths() {
  if completion has-option --no-index; then
    completion files
  elif completion has-option --cached --staged; then
    git diff --cached --name-only 2>/dev/null |
      while read path; do
        test -n "$path" && completion candidate "$path" --kind file
      done
  else
    git diff --name-only 2>/dev/null |
      while read path; do
        test -n "$path" && completion candidate "$path" --kind file
      done
  fi
}
```

The provider example assumes future parsed context queries from task #577.

## Trace integration

`rush complete trace INPUT` exposes manifest-derived state in a dedicated
`manifest` text section. `rush complete trace --json INPUT` exposes the same
model in the top-level `manifest` object:

```json
{
  "loaded": true,
  "path": "share/rush/completions/git.json",
  "manifestVersion": 1,
  "commandPath": ["git", "diff"],
  "precommandDepthLimited": false,
  "optionName": null,
  "optionValueIndex": null,
  "parsedOptions": [
    { "spelling": "--cached", "name": "cached", "exclusiveGroup": "diff-source" }
  ],
  "terminator": { "defined": false, "value": null, "seen": false },
  "activeArgumentState": {
    "name": "rev-or-path",
    "index": 0,
    "provider": "git.refs",
    "conditionResults": []
  },
  "matchedProviders": [
    { "id": "git.refs", "reason": "argumentState", "candidateCount": 3 }
  ],
  "suppressedOptions": [
    {
      "spelling": "--no-index",
      "reason": "exclusiveGroup",
      "by": "--cached",
      "group": "diff-source"
    }
  ],
  "fallback": { "kind": "none", "reason": "manifest provider or static manifest candidates matched" }
}
```

Trace output makes it clear whether a rule came from `.rush` declarations or
from a manifest, which providers were selected for the cursor position, and
which fallback path applied when no manifest/provider match produced candidates.
When completing an option value, `optionValueIndex` reports the zero-based value
position within a multi-value option.

## Implementation follow-up tasks

Create follow-up Tend tasks after this design is accepted:

1. Add `completion/schema/v1.schema.json` using JSON Schema draft 2020-12.
2. Implement a manifest parser/loader that compiles JSON into the existing
   completion rule graph.
3. Implement Rush semantic validation for manifests.
4. Bind manifest provider IDs to companion `.rush` functions and built-in
   providers.
5. Add lazy companion provider sourcing if feasible.
6. Add manifest-aware completion trace output, including JSON trace fields. (done)
7. Add a small Git-slice manifest fixture for engine validation.
8. Migrate one small first-party completion to prove the format before touching
   `git`.

## Open questions

- Should v1 allow `command.name` arrays, or should aliases always live in
  `aliases`?
- Should undefined `exclusiveGroup` names auto-create groups, or must all groups
  be declared in `optionGroups`?
- Should function provider existence be validated at load time, or only when the
  provider file is sourced lazily?
- Should manifest files be strict JSON only, or should Rush support JSONC for
  comments in source manifests?
- How much condition support belongs in v1 before providers become the better
  abstraction?
