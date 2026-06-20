const std = @import("std");
const ziglint = @import("ziglint");

const compile_check_targets = [_][]const u8{
    "x86_64-linux-gnu",
    "aarch64-linux-gnu",
    "x86_64-macos",
    "aarch64-macos",
    "x86_64-freebsd",
    "x86_64-openbsd",
    "x86_64-netbsd",
};

const rush_stack_size = 128 * 1024 * 1024;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const uucode = sharedUucodeModule(b, target, optimize);
    const vaxis = sharedVaxisModule(b, target, optimize, uucode);
    const zeit = b.dependency("zeit", .{
        .target = target,
        .optimize = optimize,
    }).module("zeit");
    const use_system_sqlite = b.systemIntegrationOption("sqlite3", .{ .default = false });

    // System config dir, GNU sysconfdir convention: defaults to <prefix>/etc
    // so non-root installs stay self-contained; packagers pass -Dsysconfdir=/etc.
    const sysconfdir = b.option(
        []const u8,
        "sysconfdir",
        "Directory for system-wide configuration (default: <prefix>/etc)",
    ) orelse
        b.getInstallPath(.prefix, "etc");
    const datadir = b.option(
        []const u8,
        "datadir",
        "Directory for read-only data files (default: <prefix>/share)",
    ) orelse
        b.getInstallPath(.prefix, "share");
    const build_config = b.addOptions();
    build_config.addOption([]const u8, "sysconfdir", sysconfdir);
    build_config.addOption([]const u8, "datadir", datadir);

    const exe_module = createRushRootModule(
        b,
        target,
        optimize,
        vaxis,
        uucode,
        zeit,
        build_config,
        use_system_sqlite,
        .{ .link_libc = true },
    );
    const exe = b.addExecutable(.{
        .name = "rush",
        .root_module = exe_module,
    });
    exe.stack_size = rush_stack_size;

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
    const test_filter = b.option(
        []const u8,
        "test-filter",
        "Only run unit tests whose name contains this substring",
    );
    const test_no_run = b.option(
        bool,
        "test-no-run",
        "Compile unit tests without running the test binary",
    ) orelse false;
    const test_module = createRushRootModule(
        b,
        target,
        optimize,
        vaxis,
        uucode,
        zeit,
        build_config,
        use_system_sqlite,
        .{},
    );
    const test_filters = if (test_filter) |filter| &[_][]const u8{filter} else &[_][]const u8{};
    const exe_tests = b.addTest(.{
        .root_module = test_module,
        .filters = test_filters,
        .test_runner = .{
            .path = b.path("tests/fd_safe_test_runner.zig"),
            .mode = .simple,
        },
    });
    if (test_no_run) {
        test_step.dependOn(&exe_tests.step);
    } else {
        test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    }

    const conformance_step = b.step("conformance", "Run shell conformance tests");
    addConformanceTests(b, target, optimize, exe, conformance_step);

    const differential_step = b.step("differential", "Run generated differential shell integration tests");
    addDifferentialTests(b, target, optimize, exe, differential_step);

    const fuzz_step = b.step("fuzz", "Run all fuzz targets (combine with --fuzz to actually fuzz)");
    addFuzzTarget(b, fuzz_step, target, .{
        .step_name = "fuzz-parser",
        .description = "Run parser fuzz target",
        .root_source_file = "src/fuzz/parser.zig",
        .filter = "fuzz parser",
        .source_module_name = "rush-parser",
        .source_module_root = "src/shell/parser.zig",
    });
    const shell_fuzz_step = b.step("fuzz-shell", "Run all shell semantic fuzz targets");
    fuzz_step.dependOn(shell_fuzz_step);
    for (shell_fuzz_targets) |fuzz_target| addFuzzTarget(b, shell_fuzz_step, target, fuzz_target);

    const compile_check_step = b.step("compile-check", "Compile-check Linux/macOS/BSD targets");
    addCompileChecks(b, compile_check_step, optimize, build_config, use_system_sqlite);

    const ziglint_dep = b.dependency("ziglint", .{ .optimize = .ReleaseFast });
    const lint_step = b.step("lint", "Run ziglint");
    lint_step.dependOn(ziglint.addLint(b, ziglint_dep, &.{
        b.path("build.zig"),
        b.path("fuzz"),
        b.path("src"),
        b.path("tests"),
    }));
}

const RushRootModuleOptions = struct {
    link_libc: bool = false,
};

fn addCompileChecks(
    b: *std.Build,
    compile_check_step: *std.Build.Step,
    optimize: std.builtin.OptimizeMode,
    build_config: *std.Build.Step.Options,
    use_system_sqlite: bool,
) void {
    for (compile_check_targets) |target_name| {
        const target_query = std.Target.Query.parse(.{ .arch_os_abi = target_name }) catch |err|
            std.debug.panic("invalid compile-check target '{s}': {s}", .{ target_name, @errorName(err) });
        const check_target = b.resolveTargetQuery(target_query);
        const check_uucode = sharedUucodeModule(b, check_target, optimize);
        const check_vaxis = sharedVaxisModule(b, check_target, optimize, check_uucode);
        const check_zeit = b.dependency("zeit", .{
            .target = check_target,
            .optimize = optimize,
        }).module("zeit");
        const check_module = createRushRootModule(
            b,
            check_target,
            optimize,
            check_vaxis,
            check_uucode,
            check_zeit,
            build_config,
            use_system_sqlite,
            .{ .link_libc = true },
        );
        const check = b.addExecutable(.{
            .name = b.fmt("rush-{s}", .{target_name}),
            .root_module = check_module,
        });
        check.stack_size = rush_stack_size;
        compile_check_step.dependOn(&check.step);
    }
}

fn addConformanceTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    rush: *std.Build.Step.Compile,
    conformance_step: *std.Build.Step,
) void {
    const harness = b.addExecutable(.{
        .name = "rush-conformance-harness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/harness.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    if (b.args) |args| {
        if (usesCustomConformanceRunner(args)) {
            const run_posix = b.addRunArtifact(harness);
            run_posix.addArgs(args);
            conformance_step.dependOn(&run_posix.step);

            if (conformanceArgsSelectPosix(args) and
                !conformanceArgsSelectInteractive(args) and
                !conformanceArgsHaveSuiteFiles(args))
            {
                const run_interactive = b.addRunArtifact(harness);
                run_interactive.addArgs(args);
                run_interactive.addArg("--interactive");
                conformance_step.dependOn(&run_interactive.step);
            }
        } else {
            const run_posix = b.addRunArtifact(harness);
            run_posix.addArg("--rush");
            run_posix.addArtifactArg(rush);
            run_posix.addArg("--mode");
            run_posix.addArg("posix");
            run_posix.addArgs(args);
            conformance_step.dependOn(&run_posix.step);

            if (!conformanceArgsSelectInteractive(args) and !conformanceArgsHaveSuiteFiles(args)) {
                const run_interactive = b.addRunArtifact(harness);
                run_interactive.addArg("--rush");
                run_interactive.addArtifactArg(rush);
                run_interactive.addArg("--mode");
                run_interactive.addArg("posix");
                run_interactive.addArgs(args);
                run_interactive.addArg("--interactive");
                conformance_step.dependOn(&run_interactive.step);
            }
        }
    } else {
        const run_posix = b.addRunArtifact(harness);
        run_posix.addArg("--rush");
        run_posix.addArtifactArg(rush);
        run_posix.addArg("--mode");
        run_posix.addArg("posix");
        conformance_step.dependOn(&run_posix.step);

        const run_interactive = b.addRunArtifact(harness);
        run_interactive.addArg("--rush");
        run_interactive.addArtifactArg(rush);
        run_interactive.addArg("--mode");
        run_interactive.addArg("posix");
        run_interactive.addArg("--interactive");
        conformance_step.dependOn(&run_interactive.step);

        const run_bash = b.addRunArtifact(harness);
        run_bash.addArg("--rush");
        run_bash.addArtifactArg(rush);
        run_bash.addArg("--mode");
        run_bash.addArg("bash");
        conformance_step.dependOn(&run_bash.step);
    }
}

fn usesCustomConformanceRunner(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--rush") or std.mem.eql(u8, arg, "--shell")) return true;
    }
    return false;
}

fn conformanceArgsSelectPosix(args: []const []const u8) bool {
    for (args, 0..) |arg, index| {
        if (std.mem.eql(u8, arg, "--mode")) {
            return index + 1 < args.len and std.mem.eql(u8, args[index + 1], "posix");
        }
    }
    return false;
}

fn conformanceArgsSelectInteractive(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--interactive")) return true;
    }
    return false;
}

fn conformanceArgsHaveSuiteFiles(args: []const []const u8) bool {
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--rush") or
            std.mem.eql(u8, arg, "--shell") or
            std.mem.eql(u8, arg, "--shell-arg") or
            std.mem.eql(u8, arg, "--mode") or
            std.mem.eql(u8, arg, "--case"))
        {
            index += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--diff") or std.mem.eql(u8, arg, "--interactive")) continue;
        if (std.mem.startsWith(u8, arg, "--")) continue;
        return true;
    }
    return false;
}

fn addDifferentialTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    rush: *std.Build.Step.Compile,
    differential_step: *std.Build.Step,
) void {
    const harness = b.addExecutable(.{
        .name = "rush-differential-harness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("fuzz/differential.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run = b.addRunArtifact(harness);
    run.addArg("--rush");
    run.addArtifactArg(rush);
    if (b.args) |args| run.addArgs(args);
    differential_step.dependOn(&run.step);
}

fn createRushRootModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    vaxis: *std.Build.Module,
    uucode: *std.Build.Module,
    zeit: *std.Build.Module,
    build_config: *std.Build.Step.Options,
    use_system_sqlite: bool,
    options: RushRootModuleOptions,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = options.link_libc,
        .imports = &.{
            .{ .name = "vaxis", .module = vaxis },
            .{ .name = "uucode", .module = uucode },
            .{ .name = "zeit", .module = zeit },
        },
    });
    module.addOptions("build_config", build_config);
    module.addAnonymousImport("default_config", .{ .root_source_file = b.path("share/rush/config.rush") });
    linkSqlite(b, module, use_system_sqlite);
    return module;
}

const FuzzTargetOptions = struct {
    step_name: []const u8,
    description: []const u8,
    root_source_file: []const u8,
    filter: []const u8,
    source_module_name: []const u8,
    source_module_root: []const u8,
    link_libc: bool = false,
};

const shell_fuzz_targets = [_]FuzzTargetOptions{
    .{
        .step_name = "fuzz-shell-delta",
        .description = "Run shell semantic StateDelta fuzz target",
        .root_source_file = "src/fuzz/shell.zig",
        .filter = "fuzz shell delta commit and discard",
        .source_module_name = "rush-shell",
        .source_module_root = "src/shell.zig",
        .link_libc = true,
    },
    .{
        .step_name = "fuzz-shell-consequence",
        .description = "Run shell consequence policy fuzz target",
        .root_source_file = "src/fuzz/shell.zig",
        .filter = "fuzz shell consequence policy",
        .source_module_name = "rush-shell",
        .source_module_root = "src/shell.zig",
        .link_libc = true,
    },
    .{
        .step_name = "fuzz-shell-redirection",
        .description = "Run shell redirection rollback fuzz target",
        .root_source_file = "src/fuzz/shell.zig",
        .filter = "fuzz shell redirection rollback",
        .source_module_name = "rush-shell",
        .source_module_root = "src/shell.zig",
        .link_libc = true,
    },
    .{
        .step_name = "fuzz-shell-eval-redirection",
        .description = "Run shell eval redirection invariant fuzz target",
        .root_source_file = "src/fuzz/shell.zig",
        .filter = "fuzz shell eval redirection invariants",
        .source_module_name = "rush-shell",
        .source_module_root = "src/shell.zig",
        .link_libc = true,
    },
    .{
        .step_name = "fuzz-shell-eval-pipeline",
        .description = "Run shell eval pipeline invariant fuzz target",
        .root_source_file = "src/fuzz/shell.zig",
        .filter = "fuzz shell eval pipeline invariants",
        .source_module_name = "rush-shell",
        .source_module_root = "src/shell.zig",
        .link_libc = true,
    },
};

fn addFuzzTarget(
    b: *std.Build,
    umbrella: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    options: FuzzTargetOptions,
) void {
    // Zig 0.16.0's bundled fuzz runner fails to compile in Debug mode through
    // the self-hosted backend. ReleaseSafe uses LLVM and preserves runtime
    // safety checks, so fuzzing still catches parser/runtime bugs without a
    // vendored test runner.
    const fuzz_optimize: std.builtin.OptimizeMode = .ReleaseSafe;
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(options.root_source_file),
            .target = target,
            .optimize = fuzz_optimize,
            .link_libc = options.link_libc,
        }),
        .filters = &.{options.filter},
    });
    const source_module = b.createModule(.{
        .root_source_file = b.path(options.source_module_root),
        .target = target,
        .optimize = fuzz_optimize,
        .link_libc = options.link_libc,
    });
    if (std.mem.eql(u8, options.source_module_root, "src/shell.zig")) {
        source_module.addImport("uucode", sharedUucodeModule(b, target, fuzz_optimize));
    }
    tests.root_module.addImport(options.source_module_name, source_module);
    const run = b.addRunArtifact(tests);
    const step = b.step(options.step_name, options.description);
    step.dependOn(&run.step);
    umbrella.dependOn(&run.step);
}

fn sharedVaxisModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    uucode: *std.Build.Module,
) *std.Build.Module {
    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
        .external_uucode = true,
    }).module("vaxis");
    vaxis.addImport("uucode", uucode);
    return vaxis;
}

fn sharedUucodeModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.dependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .fields = @as([]const []const u8, &.{
            "east_asian_width",
            "grapheme_break",
            "general_category",
            "is_emoji_presentation",
        }),
    }).module("uucode");
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
