# AGENTS.md

## Zig Development

Use `zigdoc` to discover current APIs for the Zig standard library and any third-party dependencies before coding.

Examples:
```bash
zigdoc std.fs
zigdoc std.posix.getuid
zigdoc vaxis.Window
```

## Validation

Use these commands for repository validation:

```bash
zig build lint
zig build test
zig build compile-check
```

## Current Zig Patterns

**ArrayList:**
```zig
var list: std.ArrayList(u32) = .empty;
defer list.deinit(allocator);
try list.append(allocator, 42);
```

**HashMap/StringHashMap (default to unmanaged):**
```zig
var map: std.StringHashMapUnmanaged(u32) = .empty;
defer map.deinit(allocator);
try map.put(allocator, "key", 42);
```

**stdout/stderr writer:**
```zig
var buf: [4096]u8 = undefined;
var writer = std.fs.File.stdout().writer(&buf);
defer writer.interface.flush() catch {};
try writer.interface.print("hello {s}\n", .{"world"});
```

**build.zig executable:**
```zig
b.addExecutable(.{
    .name = "foo",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
```

**JSON writing:**
```zig
var buf: [4096]u8 = undefined;
var writer = std.fs.File.stdout().writer(&buf);
defer writer.interface.flush() catch {};

var jw: std.json.Stringify = .{
    .writer = &writer.interface,
    .options = .{ .whitespace = .indent_2 },
};
try jw.write(my_struct);
```

**Allocating writer:**
```zig
var writer: std.Io.Writer.Allocating = .init(allocator);
defer writer.deinit();
try writer.writer.print("hello {s}", .{"world"});
const output = try writer.toOwnedSlice();
```

## Zig Style

- `camelCase` for functions and methods
- lower-case `snake_case` for variables, parameters, and constants
- `PascalCase` for types, structs, and enums
- file names are usually `snake_case.zig`, but may be `PascalCase.zig` when
  the file's domain is one primary type, such as `Foo.zig` with
  `const Foo = @This();`
- prefer `const foo: Type = .{ .field = value };` over `const foo = Type{ .field = value };`
- preferred file order: `//!` module doc comment, `const Self = @This();`, imports, `const log = std.log.scoped(...)`
- pass allocators explicitly; use `errdefer` for cleanup on error
- keep tests inline with the code they cover; register them in `src/main.zig`
- keep lines under 120 characters
- prefer Zig multiline string literals over string concatenation with `++` for
  long strings

## Architecture

- Prefer a functional core with an imperative shell: policy, planning, pure
  computation, and state transitions belong in deterministic core types; code
  that performs irreversible effects should be a thin, policy-free adapter.
- Dependency injection is only a boundary mechanism for effectful ports, not a
  generic container or a reason to mock every operation.
- Make ownership and mutation boundaries explicit. Many bugs are state commits
  to the wrong owner, lifetime, process, or abstraction layer; in shell execution,
  this especially means making current-shell vs child/subshell mutation explicit.
- Shape semantic objects so invariants are checked where plans, deltas, outcomes,
  and state transitions are constructed or committed.
- For shell execution specifically, keep shell policy in `src/shell/*` and POSIX
  effects like fork/exec/wait, fd operations, cwd/fs, signals, and tty I/O in
  boring `src/runtime/*` adapters.

## Safety

- Use TigerStyle/TigerBeetle-like assertions at API boundaries, state transitions,
  plan construction, and commit/discard points; avoid trivial assertions.
- Assertions are for Rush/programmer/model bugs only: impossible states,
  contradictory mutations, invalid plan shapes, mismatched counts, invalid enum
  combinations, or mutation targets that violate the semantic model.
- Ordinary user/script/input/runtime errors must be diagnostics, error values,
  statuses, or `CommandOutcome` values, not assertions: syntax errors, command
  not found, permission denied, failed redirections, readonly assignment
  failures, invalid builtin usage, parse failures, malformed input, missing
  files, and other expected behavior.
- Keep functions small and push pure computation into helpers.
- Comments should explain why, not what.
