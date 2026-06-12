#!/bin/sh
set -eu

schema=website/completion/schema/v1.schema.json
examples=website/completion/schema/examples

python3 - <<'PY'
import json
import pathlib
import re
import sys

schema_path = pathlib.Path("website/completion/schema/v1.schema.json")
examples_dir = pathlib.Path("website/completion/schema/examples")

with schema_path.open() as f:
    schema = json.load(f)

errors = []

if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
    errors.append("schema must use JSON Schema draft 2020-12")
if schema.get("$id") != "https://rush.horse/completion/schema/v1.schema.json":
    errors.append("schema $id must be https://rush.horse/completion/schema/v1.schema.json")
if schema.get("properties", {}).get("manifestVersion", {}).get("const") != 1:
    errors.append("schema must require manifestVersion const 1")
if "version" in schema.get("properties", {}):
    errors.append("schema must use manifestVersion, not version")

name_re = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
long_re = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]*$")
function_re = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
provider_re = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
allowed_builtin = {"files", "directories", "executables", "variables"}
allowed_value_style = {"detached", "attached", "attached-or-detached", "equals", "optional"}


def path_join(path, key):
    if isinstance(key, int):
        return f"{path}[{key}]"
    return f"{path}.{key}" if path else key


def check_name(value, path):
    if isinstance(value, str):
        if not name_re.match(value):
            errors.append(f"{path}: invalid name {value!r}")
    elif isinstance(value, list) and value:
        seen = set()
        for i, item in enumerate(value):
            check_name(item, path_join(path, i))
            if item in seen:
                errors.append(f"{path}: duplicate name {item!r}")
            seen.add(item)
    else:
        errors.append(f"{path}: expected name string or non-empty array")


def check_provider_ref(value, providers, path):
    if isinstance(value, str):
        if not provider_re.match(value):
            errors.append(f"{path}: invalid provider id {value!r}")
        elif value not in providers and not value.startswith("builtin."):
            errors.append(f"{path}: unknown provider {value!r}")
    elif isinstance(value, dict):
        check_provider(value, path)
    else:
        errors.append(f"{path}: expected provider id or provider object")


def check_provider(value, path):
    if not isinstance(value, dict):
        errors.append(f"{path}: provider must be an object")
        return
    has_function = "function" in value
    has_builtin = "builtin" in value
    if has_function == has_builtin:
        errors.append(f"{path}: provider must have exactly one of function or builtin")
    if has_function and not function_re.match(str(value["function"])):
        errors.append(f"{path}.function: invalid function name")
    if has_builtin and value["builtin"] not in allowed_builtin:
        errors.append(f"{path}.builtin: invalid builtin provider {value['builtin']!r}")
    if has_builtin and "options" in value:
        errors.append(f"{path}.options: builtin provider options are not supported in v1")


def check_value(value, providers, path):
    if not isinstance(value, dict):
        errors.append(f"{path}: value must be an object")
        return
    if "name" in value:
        check_name(value["name"], path_join(path, "name"))
    if "style" in value and value["style"] not in allowed_value_style:
        errors.append(f"{path}.style: invalid value style")
    if "provider" in value:
        check_provider_ref(value["provider"], providers, path_join(path, "provider"))


def check_option(option, providers, path):
    if not isinstance(option, dict):
        errors.append(f"{path}: option must be an object")
        return
    if "short" not in option and "long" not in option:
        errors.append(f"{path}: option needs short or long")
    if "short" in option and (not isinstance(option["short"], str) or len(option["short"]) != 1 or option["short"].isspace() or option["short"] == "-"):
        errors.append(f"{path}.short: short option must be one non-space non-dash character")
    if "long" in option and (not isinstance(option["long"], str) or not long_re.match(option["long"])):
        errors.append(f"{path}.long: invalid long option")
    for i, alias in enumerate(option.get("aliases", [])):
        if not isinstance(alias, str) or not long_re.match(alias):
            errors.append(f"{path}.aliases[{i}]: invalid long option alias")
    if "value" in option:
        check_value(option["value"], providers, path_join(path, "value"))


def check_arguments(arguments, providers, path):
    if not isinstance(arguments, dict):
        errors.append(f"{path}: arguments must be an object")
        return
    states = arguments.get("states")
    if not isinstance(states, list):
        errors.append(f"{path}.states: states must be an array")
        return
    seen = set()
    for i, state in enumerate(states):
        state_path = path_join(path_join(path, "states"), i)
        if not isinstance(state, dict):
            errors.append(f"{state_path}: state must be an object")
            continue
        name = state.get("name")
        if not isinstance(name, str):
            errors.append(f"{state_path}.name: state needs a name")
        else:
            check_name(name, path_join(state_path, "name"))
            if name in seen:
                errors.append(f"{path}.states: duplicate state {name!r}")
            seen.add(name)
        if "provider" in state:
            check_provider_ref(state["provider"], providers, path_join(state_path, "provider"))


def check_command(command, inherited_providers, path):
    if not isinstance(command, dict):
        errors.append(f"{path}: command must be an object")
        return
    if "name" not in command:
        errors.append(f"{path}.name: command needs a name")
    else:
        check_name(command["name"], path_join(path, "name"))

    providers = dict(inherited_providers)
    for provider_id, provider in command.get("providers", {}).items():
        if not provider_re.match(provider_id):
            errors.append(f"{path}.providers.{provider_id}: invalid provider id")
        check_provider(provider, path_join(path_join(path, "providers"), provider_id))
        providers[provider_id] = provider

    seen_options = set()
    for i, option in enumerate(command.get("options", [])):
        option_path = path_join(path_join(path, "options"), i)
        check_option(option, providers, option_path)
        if isinstance(option, dict):
            for spelling in (option.get("short"), option.get("long")):
                if spelling:
                    key = ("short" if len(spelling) == 1 and spelling == option.get("short") else "long", spelling)
                    if key in seen_options:
                        errors.append(f"{option_path}: duplicate option spelling {spelling!r}")
                    seen_options.add(key)

    if "arguments" in command:
        check_arguments(command["arguments"], providers, path_join(path, "arguments"))

    seen_subcommands = set()
    for i, subcommand in enumerate(command.get("subcommands", [])):
        sub_path = path_join(path_join(path, "subcommands"), i)
        if isinstance(subcommand, dict):
            names = subcommand.get("name")
            names = names if isinstance(names, list) else [names]
            for name in names:
                if isinstance(name, str):
                    if name in seen_subcommands:
                        errors.append(f"{sub_path}: duplicate subcommand name {name!r}")
                    seen_subcommands.add(name)
        check_command(subcommand, providers, sub_path)


def check_manifest(manifest, path, expect_valid):
    before = len(errors)
    if not isinstance(manifest, dict):
        errors.append(f"{path}: manifest must be an object")
    else:
        if manifest.get("manifestVersion") != 1:
            errors.append(f"{path}.manifestVersion: expected 1")
        if "version" in manifest:
            errors.append(f"{path}.version: use manifestVersion")
        if "command" not in manifest:
            errors.append(f"{path}.command: missing command")
        else:
            check_command(manifest["command"], {}, f"{path}.command")
    produced = len(errors) - before
    if expect_valid:
        return
    if produced == 0:
        errors.append(f"{path}: invalid fixture unexpectedly passed targeted validation")
    else:
        del errors[before:]

for fixture in sorted(examples_dir.glob("*.json")):
    with fixture.open() as f:
        manifest = json.load(f)
    expect_valid = fixture.name.endswith(".valid.json")
    expect_invalid = fixture.name.endswith(".invalid.json")
    if not expect_valid and not expect_invalid:
        errors.append(f"{fixture}: fixture must end with .valid.json or .invalid.json")
        continue
    check_manifest(manifest, str(fixture), expect_valid)

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(1)
PY
