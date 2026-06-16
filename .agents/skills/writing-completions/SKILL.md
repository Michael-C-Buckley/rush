---
name: writing-completions
description: >-
  Writes Rush command completions. Use when creating or editing completion
  manifests, provider functions, or completion documentation under
  share/rush/completions and website/docs.
---

# Writing Completions

Use this workflow for Rush command completions: `name.json` manifests, optional
`name.rush` provider scripts, schema examples, and related website docs.

## Sources of Truth

- `website/completion/schema/v1.schema.json` is the authoritative manifest
  schema. Read it before using fields that are not already obvious from nearby
  examples.
- `website/docs/completion-manifest.html` is the human-readable schema guide.
- `website/docs/completions.html` is the end-to-end authoring guide.
- `website/docs/builtins/rush_complete.html` documents the provider-function API.
- `share/rush/completions/git.json` and `share/rush/completions/git.rush` are the
  richest first-party examples for command trees, static providers, and
  context-sensitive dynamic providers.

## File Layout

- System completions live in `share/rush/completions/` as `command.json` plus an
  optional `command.rush` companion script.
- User completions are loaded from `$XDG_CONFIG_HOME/rush/completions`, or
  `~/.config/rush/completions` when `XDG_CONFIG_HOME` is unset.
- Completion files are loaded lazily for the command being completed. System
  completions load before user completions.

## Manifest Authoring Rules

1. Start with the minimal root shape:

   ```json
   {
     "$schema": "https://rush.horse/completion/schema/v1.schema.json",
     "manifestVersion": 1,
     "command": { "name": "tool" }
   }
   ```

2. Model the static command structure first: root options, subcommands,
   subcommand-specific options, argument states, and simple value providers.
3. Aim for complete command coverage. Include documented subcommands, common
   aliases, global options, subcommand options, option values, and positional
   operands rather than only the happy path. Use the completeness standard below
   to decide what belongs in scope.
4. Prefer manifest data over shell code. Use `{ "values": [...] }` for enums and
   `{ "builtin": "files" | "directories" | "executables" | "variables" }` for
   built-in sources before adding a function provider.
5. Put shared providers in the nearest command's `providers` object and reference
   them by stable ids like `tool.targets` or `builtin.files`.
6. Use `short` for one-character non-dash options, `long` for GNU-style long
   options without the leading `--`, and `spellings` for literal option tokens
   that do not fit those forms, such as `-iname` or `+o`.
7. Add `value` objects for option values. Use `provider` for candidates,
   `grammar` for structured values, and an array of values for multi-word option
   values.
8. Use `arguments.states` to describe positional operands. Set `index` for fixed
   positions, `repeatable` for unbounded trailing operands, and `terminator` when
   `--` changes operand interpretation.
9. Use `rest: "command-line"` only for precommand wrappers like `sudo`; do not
   combine that rest state with `repeatable`, `provider`, or `grammar`.
10. Use `optionGroups`, `exclusiveGroup`, `excludes`, `requires`, `when`, `after`,
   and `until` only when they materially improve completion behavior. Keep simple
   CLIs simple.
11. Use `platforms`, `variantProbe`, and `variants` only for real platform or
    installed-variant differences.

## Completeness Standard

Rush completions should be best-in-class. Completion authors should provide the
best completions possible for the command, not merely enough static data to avoid
falling back to filename completion.

Default to complete, documented coverage for the command area being edited. A
completion is complete when it helps in every syntactic position a user is likely
to press Tab, not merely when it lists the top-level subcommands.

- Cover command identity: primary command name, aliases, hidden/deprecated status,
  platform gates, and installed variant differences when documented.
- Cover command structure: all common documented subcommands and nested
  subcommands for the edited command area.
- Cover options: global options, inherited options, subcommand options, short and
  long spellings, literal spellings, aliases, repeatability, option terminators,
  mutual exclusions, and requirements when they affect valid completion choices.
- Cover option values: enum values, file/directory values, structured values,
  optional/attached/equals styles, and multi-word value sequences.
- Cover operands: fixed positional arguments, repeatable trailing arguments,
  command-line rest arguments, `--` behavior, and path/ref/name providers.
- Cover context: use provider functions when candidates depend on parsed options,
  previous operands, repository state, config, environment, or the current value
  position. Dynamic functions are good when they make completions more accurate.
- Cover descriptions: every visible command, option, value, and non-obvious
  operand should have a concise lowercase description.
- Do not pad with obscure, dangerous, or rarely used flags just to look large;
  include them when they are documented and useful, and mark hidden/deprecated
  forms accurately.
- If the upstream command is too large for one change, define the slice explicitly
  in the final response. The slice should be internally complete, for example
  "all `remote` subcommands" rather than "some git options".
- When intentionally leaving gaps, name the missing area and why it is out of
  scope. Do not present partial coverage as complete.

## Completion Style Guide

- Descriptions are completion-menu labels, not manpage prose. Keep every manifest
  `description` value at or below 70 characters.
- Write descriptions in all lowercase, including the first word. Prefer command
  vocabulary over marketing names unless the proper name is the candidate value.
- Use imperative, fragment-style descriptions without terminal punctuation:
  `create a branch`, `show ignored files`, `path to remove`.
- Prefer concise verbs: `show`, `list`, `create`, `remove`, `read`, `write`,
  `use`, `set`, `skip`, `include`, `exclude`, `enable`, `disable`.
- Avoid filler such as "specify", "allows you to", "the given", and "whether to"
  when a shorter phrase is clear.
- Name argument states after the semantic role being completed, such as
  `pathspec`, `remote`, `branch`, `commit`, `pattern`, or `command`.
- Name provider ids as `<command>.<plural-or-role>`; use hyphenated lowercase
  words for multi-word roles, for example `git.remote-branches`.
- Keep aliases in `aliases`; do not duplicate alias spellings as separate
  subcommands unless the command actually exposes distinct behavior.
- For large commands, group related subcommands in source order that matches the
  upstream documentation closely enough that missing entries are easy to audit.

## Candidate Ordering and Relevance

Rush should own final filtering and ordering so candidates from manifests,
builtins, paths, commands, and dynamic providers merge consistently. Completion
authors should still provide the strongest relevance signal they can.

- Emit dynamic candidates in best-first order. Put current, local, configured,
  recently used, or exact-context candidates before generic fallbacks.
- Do not alphabetize away domain knowledge in provider functions unless the
  command's natural ordering is alphabetical and no better relevance signal is
  available.
- Prefer specific candidates over broad fallbacks. For example, emit repository
  refs before filesystem paths when completing a ref-or-path position where the
  current context strongly indicates a ref.
- Rush should preserve provider emission order as a late tie-breaker after match
  quality, explicit priority, candidate class, and provider order.
- The explicit ranking API is `priority`, not `score`. Higher priority means
  "prefer this among otherwise comparable candidates", not "replace Rush's final
  ranking model".
- `priority` is a signed 8-bit integer. Omit it for default priority `0`.
- Prefer small, consistent bands: `1`-`9` for slight preference, `10`-`49` for
  strong context, `50`-`99` for exceptional context such as the current branch,
  active target, or active profile, and negative values are allowed specifically to derank fallback candidates.
- Avoid huge numbers. If two candidates need priorities like `10000` and `20000`,
  the completion probably needs clearer providers, conditions, or candidate
  grouping instead of a larger numeric scale.
- Rush adds its own query-aware ranking on top of author priority: exact matches
  before prefix matches, prefix matches before fuzzy matches, then priority and
  deterministic tie-breakers.
- Use `priority` on manifest-authored commands, options, and static enum value
  objects, or `rush_complete candidate --priority N`, only for meaningful
  relevance differences.

## Provider Function Rules

Use a `name.rush` companion only when completion needs live state or context that
cannot be represented statically. Do not avoid dynamic providers out of fear that
they are slow: provider functions run asynchronously from the editor's point of
view, so accurate live candidates are preferable to stale static guesses.

- Name functions with the existing convention: `__rush_complete_<command>_<thing>`.
- Reference them from the manifest with `{ "function": "__rush_complete_..." }`.
- Emit candidates with `rush_complete candidate VALUE --kind KIND --description TEXT`.
- Add `--priority N` only when the provider has real domain knowledge that should
  prefer one otherwise comparable candidate over another.
- Use `rush_complete files` and `rush_complete directories --append-slash` for
  path candidates unless command-specific filtering is required.
- Inspect parsed context with:
  - `rush_complete option-present --long name` or `--short x`
  - `rush_complete option-values --long name` or `--short x`
  - `rush_complete operand INDEX`
  - `$rush_completion_argument_index`
  - `$rush_completion_options_terminated`
  - `$rush_completion_value_position`
- Providers run hidden with captured output and cloned shell state. Redirect
  noisy command failures with `2>/dev/null`; never print ordinary output.
- Provider functions must not have side effects. Because they run asynchronously
  and may be canceled, superseded, or invoked repeatedly while the user edits,
  they must not mutate files, repositories, shell state, config, history,
  network state, daemons, terminals, or external services.
- Use read-only commands and queries. Avoid commands that acquire locks, refresh
  caches, start background work, prompt interactively, page output, or perform
  network I/O unless that command is explicitly documented as a safe read-only
  metadata query for completion use.
- Prefer streaming simple command output through `while read value; do ...; done`.
  For commands whose output might be reused or whose pipelines need simpler
  control flow, follow `git.rush`'s `tmp=$(mktemp)` / `rm -f "$tmp"` pattern.
- Keep provider functions small and context-specific. Put reusable primitive
  providers, such as branches or remotes, above higher-level context providers.

## Validation

- At minimum, verify edited manifests are valid JSON, for example:

  ```bash
  python3 -m json.tool share/rush/completions/tool.json >/dev/null
  ```

- For completion engine or loader changes, run the focused tests around
  `src/completion.zig` or the repository validation commands from `AGENTS.md` as
  appropriate.
- For website changes, check the generated/static HTML you edited directly; the
  docs are plain HTML in this repository.

## Review Checklist

- Manifest includes `$schema`, `manifestVersion: 1`, and a root `command.name`.
- Option spellings match the schema shape and omit leading dashes for `long`.
- Every provider reference is defined or is an inline provider object.
- Function providers named in JSON exist in the matching `.rush` file.
- Dynamic providers account for option values, `--`, and positional index when
  the command's grammar changes completion meaning.
- Descriptions are concise and useful in the completion menu.
- Static data remains in JSON; `.rush` code is reserved for live/contextual data.
