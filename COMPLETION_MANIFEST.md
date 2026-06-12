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
  value?: Value
  repeatable?: boolean
  exclusiveGroup?: string
  requires?: string[]
  terminatesOptions?: boolean
  hidden?: boolean
  deprecated?: boolean | string
}

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
  provider?: ProviderRef
  grammar?: ValueGrammar
  description?: string
  when?: Condition
  after?: Condition
  until?: Condition
}

type Provider =
  | { function: string, description?: string, lazy?: boolean }
  | { builtin: "files" | "directories" | "executables" | "variables", options?: object }

type ProviderRef = string | Provider
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
    "builtin.directories": {
      "builtin": "directories",
      "options": { "appendSlash": true }
    }
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
      "builtin.directories": {
        "builtin": "directories",
        "options": { "appendSlash": true }
      }
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

`rush complete trace --json` should expose manifest-derived state:

```json
{
  "manifest": "share/rush/completions/git.json",
  "manifestVersion": 1,
  "commandPath": ["git", "diff"],
  "position": "argument",
  "options": {
    "cached": { "present": true, "spelling": "--cached" }
  },
  "terminatorSeen": false,
  "argumentState": "rev-or-path",
  "matchedProviders": ["git.refs"],
  "suppressedOptions": [
    {
      "option": "--no-index",
      "reason": "exclusive group diff-source already satisfied by --cached"
    }
  ]
}
```

Trace output should make it clear whether a rule came from `.rush` declarations
or from a manifest.

## Implementation follow-up tasks

Create follow-up Tend tasks after this design is accepted:

1. Add `completion/schema/v1.schema.json` using JSON Schema draft 2020-12.
2. Implement a manifest parser/loader that compiles JSON into the existing
   completion rule graph.
3. Implement Rush semantic validation for manifests.
4. Bind manifest provider IDs to companion `.rush` functions and built-in
   providers.
5. Add lazy companion provider sourcing if feasible.
6. Add manifest-aware completion trace output, including JSON trace fields.
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
