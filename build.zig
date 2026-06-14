const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Only run unit tests whose name contains this string");
    const test_filters: []const []const u8 = if (test_filter) |filter| &.{filter} else &.{};
    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    }).module("vaxis");
    const zeit = b.dependency("zeit", .{
        .target = target,
        .optimize = optimize,
    }).module("zeit");
    const use_system_sqlite = b.systemIntegrationOption("sqlite3", .{ .default = false });

    // System config dir, GNU sysconfdir convention: defaults to <prefix>/etc
    // so non-root installs stay self-contained; packagers pass -Dsysconfdir=/etc.
    const sysconfdir = b.option([]const u8, "sysconfdir", "Directory for system-wide configuration (default: <prefix>/etc)") orelse
        b.getInstallPath(.prefix, "etc");
    const build_config = b.addOptions();
    build_config.addOption([]const u8, "sysconfdir", sysconfdir);

    const exe = b.addExecutable(.{
        .name = "rush",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "vaxis", .module = vaxis },
                .{ .name = "zeit", .module = zeit },
            },
        }),
    });
    exe.root_module.addOptions("build_config", build_config);
    exe.root_module.addAnonymousImport("default_config", .{ .root_source_file = b.path("share/rush/config.rush") });
    linkSqlite(b, exe.root_module, use_system_sqlite);

    b.installArtifact(exe);
    b.installDirectory(.{
        .source_dir = b.path("share/rush/completions"),
        .install_dir = .{ .custom = "share/rush/completions" },
        .install_subdir = "",
        .include_extensions = &.{ ".rush", ".json" },
        .exclude_extensions = &.{},
        .blank_extensions = &.{},
    });

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const exe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vaxis", .module = vaxis },
                .{ .name = "zeit", .module = zeit },
            },
        }),
        .filters = test_filters,
        .test_runner = .{ .path = b.path("test/support/timing_test_runner.zig"), .mode = .simple },
    });
    exe_tests.root_module.addOptions("build_config", build_config);
    exe_tests.root_module.addAnonymousImport("default_config", .{ .root_source_file = b.path("share/rush/config.rush") });
    linkSqlite(b, exe_tests.root_module, use_system_sqlite);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    const fuzz_step = b.step("fuzz", "Run all fuzz targets (combine with --fuzz to actually fuzz)");
    addFuzzTarget(b, fuzz_step, target, optimize, .{
        .step_name = "fuzz-parser",
        .description = "Run parser fuzz target",
        .root_source_file = "src/fuzz/parser.zig",
        .filter = "fuzz parser",
        .source_module_name = "rush-parser",
        .source_module_root = "src/shell/parser.zig",
    });
    const shell_fuzz_step = b.step("fuzz-shell", "Run all shell semantic fuzz targets");
    fuzz_step.dependOn(shell_fuzz_step);
    addFuzzTarget(b, shell_fuzz_step, target, optimize, .{
        .step_name = "fuzz-shell-delta",
        .description = "Run shell semantic StateDelta fuzz target",
        .root_source_file = "src/fuzz/shell.zig",
        .filter = "fuzz shell delta commit and discard",
        .source_module_name = "rush-shell",
        .source_module_root = "src/shell.zig",
        .link_libc = true,
    });
    addFuzzTarget(b, shell_fuzz_step, target, optimize, .{
        .step_name = "fuzz-shell-consequence",
        .description = "Run shell consequence policy fuzz target",
        .root_source_file = "src/fuzz/shell.zig",
        .filter = "fuzz shell consequence policy",
        .source_module_name = "rush-shell",
        .source_module_root = "src/shell.zig",
        .link_libc = true,
    });
    addFuzzTarget(b, shell_fuzz_step, target, optimize, .{
        .step_name = "fuzz-shell-redirection",
        .description = "Run shell redirection rollback fuzz target",
        .root_source_file = "src/fuzz/shell.zig",
        .filter = "fuzz shell redirection rollback",
        .source_module_name = "rush-shell",
        .source_module_root = "src/shell.zig",
        .link_libc = true,
    });
    addFuzzTarget(b, shell_fuzz_step, target, optimize, .{
        .step_name = "fuzz-shell-eval-redirection",
        .description = "Run shell eval redirection invariant fuzz target",
        .root_source_file = "src/fuzz/shell.zig",
        .filter = "fuzz shell eval redirection invariants",
        .source_module_name = "rush-shell",
        .source_module_root = "src/shell.zig",
        .link_libc = true,
    });
    addFuzzTarget(b, shell_fuzz_step, target, optimize, .{
        .step_name = "fuzz-shell-eval-pipeline",
        .description = "Run shell eval pipeline invariant fuzz target",
        .root_source_file = "src/fuzz/shell.zig",
        .filter = "fuzz shell eval pipeline invariants",
        .source_module_name = "rush-shell",
        .source_module_root = "src/shell.zig",
        .link_libc = true,
    });

    const check_step = b.step("check", "Run unit tests and repository validation checks");
    check_step.dependOn(test_step);

    const compile_test_step = b.step("compile-test", "Compile unit tests without running them");
    compile_test_step.dependOn(&exe_tests.step);

    const completion_validate_step = b.step("completion-validate", "Validate shipped Rush completion scripts");
    const completion_validate = b.addSystemCommand(&.{
        "sh",
        "-c",
        "for script in share/rush/completions/*.rush; do \"$1\" complete validate \"$script\"; done",
        "sh",
    });
    completion_validate.addArtifactArg(exe);
    completion_validate_step.dependOn(&completion_validate.step);

    const invocation_stdin_check = b.addSystemCommand(&.{
        "sh",
        "-c",
        \\set -eu
        \\tmp=$(mktemp -d)
        \\trap 'rm -rf "$tmp"' EXIT
        \\printf '%s\n' 'echo hi' | "$1" >"$tmp/stdout" 2>"$tmp/stderr"
        \\test "$(cat "$tmp/stdout")" = hi
        \\test ! -s "$tmp/stderr"
        \\printf '%s\n' 'echo "$1"' | "$1" -s posarg >"$tmp/stdout" 2>"$tmp/stderr"
        \\test "$(cat "$tmp/stdout")" = posarg
        \\test ! -s "$tmp/stderr"
        \\printf 'pipe value\n' | "$1" -c 'read x; status=$?; printf "x=[%s] status=%s\n" "$x" "$status"' >"$tmp/stdout" 2>"$tmp/stderr"
        \\test "$(cat "$tmp/stdout")" = 'x=[pipe value] status=0'
        \\test ! -s "$tmp/stderr"
        \\printf 'file value\n' >"$tmp/input"
        \\"$1" -c 'read x; status=$?; printf "x=[%s] status=%s\n" "$x" "$status"' <"$tmp/input" >"$tmp/stdout" 2>"$tmp/stderr"
        \\test "$(cat "$tmp/stdout")" = 'x=[file value] status=0'
        \\test ! -s "$tmp/stderr"
        \\printf 'redirected value\n' >"$tmp/redirect"
        \\printf 'real stdin value\n' | "$1" -c 'read x < "$1"; status=$?; printf "x=[%s] status=%s\n" "$x" "$status"' rush "$tmp/redirect" >"$tmp/stdout" 2>"$tmp/stderr"
        \\test "$(cat "$tmp/stdout")" = 'x=[redirected value] status=0'
        \\test ! -s "$tmp/stderr"
        \\if "$1" -e -c 'false; echo no' >"$tmp/stdout" 2>"$tmp/stderr"; then exit 1; else status=$?; fi
        \\test "$status" = 1
        \\test ! -s "$tmp/stdout"
        \\test ! -s "$tmp/stderr"
        \\if "$1" -ec 'false; echo no' >"$tmp/stdout" 2>"$tmp/stderr"; then exit 1; else status=$?; fi
        \\test "$status" = 1
        \\test ! -s "$tmp/stdout"
        \\test ! -s "$tmp/stderr"
        \\if "$1" -c -e 'false; echo no' >"$tmp/stdout" 2>"$tmp/stderr"; then exit 1; else status=$?; fi
        \\test "$status" = 1
        \\test ! -s "$tmp/stdout"
        \\test ! -s "$tmp/stderr"
        \\"$1" -ec 'printf "%s:%s:%s\n" "$0" "$1" "$2"' name one two >"$tmp/stdout" 2>"$tmp/stderr"
        \\test "$(cat "$tmp/stdout")" = 'name:one:two'
        \\test ! -s "$tmp/stderr"
        \\"$1" -sc 'printf "%s:%s\n" "$0" "$1"' name one >"$tmp/stdout" 2>"$tmp/stderr"
        \\test "$(cat "$tmp/stdout")" = 'name:one'
        \\test ! -s "$tmp/stderr"
        \\cat >"$tmp/read-script.rush" <<'EOF'
        \\read x; status=$?; printf 'x=[%s] status=%s\n' "$x" "$status"
        \\EOF
        \\printf 'script pipe value\n' | "$1" "$tmp/read-script.rush" >"$tmp/stdout" 2>"$tmp/stderr"
        \\test "$(cat "$tmp/stdout")" = 'x=[script pipe value] status=0'
        \\test ! -s "$tmp/stderr"
        \\printf '%s\n' 'read x; status=$?; printf "x=[%s] status=%s\n" "$x" "$status"' | "$1" >"$tmp/stdout" 2>"$tmp/stderr"
        \\test "$(cat "$tmp/stdout")" = 'x=[] status=1'
        \\test ! -s "$tmp/stderr"
        ,
        "sh",
    });
    invocation_stdin_check.addArtifactArg(exe);

    const bracket_loop_benchmark_step = b.step("bracket-loop-benchmark", "Check that [ builtin loops do not trigger glob directory scans");
    const bracket_loop_benchmark = b.addSystemCommand(&.{"env"});
    bracket_loop_benchmark.addPrefixedArtifactArg("RUSH=", exe);
    bracket_loop_benchmark.addArgs(&.{ "sh", "scripts/check-bracket-loop-benchmark.sh" });
    bracket_loop_benchmark.step.dependOn(&exe.step);
    bracket_loop_benchmark.setEnvironmentVariable("RUSH_SKIP_BUILD", "1");
    bracket_loop_benchmark_step.dependOn(&bracket_loop_benchmark.step);

    const install_completion_manifest_check_step = b.step("completion-install-check", "Verify installed completion manifests load from XDG data dirs");
    const install_completion_manifest_check = b.addSystemCommand(&.{
        "sh",
        "-c",
        \\set -eu
        \\zig=$1
        \\tmp=$(mktemp -d)
        \\trap 'rm -rf "$tmp"' EXIT
        \\"$zig" build install --prefix "$tmp/prefix" --summary none
        \\bin=$tmp/prefix/bin/rush
        \\share=$tmp/prefix/share
        \\test -f "$share/rush/completions/git.rush"
        \\test -f "$share/rush/completions/git.json"
        \\mkdir -p "$tmp/home" "$tmp/config"
        \\env -i PATH="${PATH:-/usr/bin:/bin}" HOME="$tmp/home" XDG_DATA_HOME= XDG_CONFIG_HOME="$tmp/config" XDG_DATA_DIRS="$share" "$bin" complete --debug 'git sw' >"$tmp/output"
        \\grep -q 'source: manifest' "$tmp/output"
        \\grep -q 'manifest-path: .*share/rush/completions/git.json' "$tmp/output"
        \\grep -q 'insert: switch' "$tmp/output"
        ,
        "sh",
    });
    install_completion_manifest_check.addArg(b.graph.zig_exe);
    install_completion_manifest_check_step.dependOn(&install_completion_manifest_check.step);

    const fmt_step = b.step("fmt", "Check code formatting");
    const fmt_check = b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" }, .check = true });
    fmt_step.dependOn(&fmt_check.step);
    check_step.dependOn(fmt_step);
    check_step.dependOn(&completion_validate.step);
    check_step.dependOn(&invocation_stdin_check.step);
    check_step.dependOn(&bracket_loop_benchmark.step);
    check_step.dependOn(&install_completion_manifest_check.step);

    const cross_check_step = b.step("cross-check", "Run native tests and compile-check Linux/macOS/BSD targets");
    const cross_check = b.addSystemCommand(&.{
        "sh",
        "-c",
        \\set -eu
        \\zig=$1
        \\"$zig" build test --summary all
        \\for target in \
        \\  x86_64-linux-gnu \
        \\  aarch64-linux-gnu \
        \\  x86_64-macos \
        \\  aarch64-macos \
        \\  x86_64-freebsd \
        \\  x86_64-openbsd \
        \\  x86_64-netbsd
        \\do
        \\  echo "compile-check $target"
        \\  "$zig" build compile-test -Dtarget="$target" --summary none
        \\done
        ,
        "sh",
    });
    cross_check.addArg(b.graph.zig_exe);
    cross_check.step.dependOn(fmt_step);
    cross_check_step.dependOn(&cross_check.step);

    const corpus_step = b.step("corpus", "Compare supported behavior corpus against available system shells");
    const corpus_check = b.addSystemCommand(&.{ "sh", "scripts/check-system-shell-corpus.sh" });
    corpus_check.step.dependOn(&exe.step);
    corpus_check.step.dependOn(fmt_step);
    corpus_check.setEnvironmentVariable("RUSH_SKIP_BUILD", "1");
    corpus_step.dependOn(&corpus_check.step);
    check_step.dependOn(&corpus_check.step);

    const posix_corpus_step = b.step("posix-corpus", "Run spec-derived POSIX expected-output corpus");
    const posix_corpus_check = b.addSystemCommand(&.{"env"});
    posix_corpus_check.addPrefixedArtifactArg("RUSH=", exe);
    posix_corpus_check.addArgs(&.{ "sh", "scripts/check-posix-corpus.sh" });
    posix_corpus_check.step.dependOn(&exe.step);
    posix_corpus_check.step.dependOn(fmt_step);
    posix_corpus_check.setEnvironmentVariable("RUSH_SKIP_BUILD", "1");
    posix_corpus_step.dependOn(&posix_corpus_check.step);
    check_step.dependOn(&posix_corpus_check.step);

    const compliance_manifest_step = b.step("compliance-manifest", "Validate POSIX compliance manifest schema and references");
    const compliance_manifest_check = b.addSystemCommand(&.{ "sh", "scripts/check-compliance-manifest.sh" });
    compliance_manifest_check.step.dependOn(fmt_step);
    compliance_manifest_step.dependOn(&compliance_manifest_check.step);
    check_step.dependOn(&compliance_manifest_check.step);

    const completion_manifest_schema_step = b.step("completion-manifest-schema", "Validate completion manifest schema and examples");
    const completion_manifest_schema_check = b.addSystemCommand(&.{ "sh", "scripts/check-completion-manifest-schema.sh" });
    completion_manifest_schema_check.step.dependOn(fmt_step);
    completion_manifest_schema_step.dependOn(&completion_manifest_schema_check.step);
    check_step.dependOn(&completion_manifest_schema_check.step);

    const posix_negative_corpus_step = b.step("posix-negative-corpus", "Run POSIX negative diagnostics corpus");
    const posix_negative_corpus_check = b.addSystemCommand(&.{"env"});
    posix_negative_corpus_check.addPrefixedArtifactArg("RUSH=", exe);
    posix_negative_corpus_check.addArgs(&.{ "sh", "scripts/check-posix-negative-corpus.sh" });
    posix_negative_corpus_check.step.dependOn(&exe.step);
    posix_negative_corpus_check.step.dependOn(fmt_step);
    posix_negative_corpus_check.setEnvironmentVariable("RUSH_SKIP_BUILD", "1");
    posix_negative_corpus_step.dependOn(&posix_negative_corpus_check.step);
    check_step.dependOn(&posix_negative_corpus_check.step);

    const compliance_step = b.step("compliance", "Report POSIX compliance metrics and validate corpora");
    const compliance_report = b.addSystemCommand(&.{ "sh", "scripts/report-compliance.sh", "--run-corpora" });
    compliance_report.step.dependOn(&exe.step);
    compliance_report.step.dependOn(fmt_step);
    compliance_step.dependOn(&compliance_report.step);
}

const FuzzTargetOptions = struct {
    step_name: []const u8,
    description: []const u8,
    root_source_file: []const u8,
    filter: []const u8,
    source_module_name: ?[]const u8 = null,
    source_module_root: ?[]const u8 = null,
    link_libc: bool = false,
};

fn addFuzzTarget(b: *std.Build, umbrella: *std.Build.Step, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, options: FuzzTargetOptions) void {
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(options.root_source_file),
            .target = target,
            .optimize = optimize,
            .link_libc = options.link_libc,
        }),
        .filters = &.{options.filter},
        // Patched copy of the default runner; Zig 0.16.0's bundled runner
        // fails to compile under --fuzz (see the file's doc comment).
        .test_runner = .{ .path = b.path("test/support/fuzz_test_runner.zig"), .mode = .server },
    });
    if (options.source_module_name) |name| {
        const root = options.source_module_root orelse @panic("fuzz source module root missing");
        tests.root_module.addImport(name, b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
            .link_libc = options.link_libc,
        }));
    }
    const run = b.addRunArtifact(tests);
    const step = b.step(options.step_name, options.description);
    step.dependOn(&run.step);
    umbrella.dependOn(&run.step);
}

fn linkSqlite(b: *std.Build, module: *std.Build.Module, use_system_sqlite: bool) void {
    if (use_system_sqlite) {
        module.linkSystemLibrary("sqlite3", .{
            .use_pkg_config = .yes,
            .preferred_link_mode = .dynamic,
            .search_strategy = .paths_first,
        });
        return;
    }

    const sqlite = b.dependency("sqlite", .{});
    // Built as a separate static library so `zig build fuzz --fuzz` does not
    // instrument the C code; clang's sancov emits callbacks (e.g.
    // __sanitizer_cov_trace_switch) that Zig's fuzzer runtime does not provide.
    const lib = b.addLibrary(.{
        .name = "sqlite3",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = module.resolved_target,
            .optimize = module.optimize,
            .link_libc = true,
            .fuzz = false,
        }),
    });
    lib.root_module.addCSourceFile(.{
        .file = sqlite.path("sqlite3.c"),
        .flags = &.{
            "-DSQLITE_ENABLE_FTS5",
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_DEFAULT_MEMSTATUS=0",
        },
    });
    module.linkLibrary(lib);
    module.addIncludePath(sqlite.path("."));
    module.link_libc = true;
}
