const std = @import("std");

const compile_check_targets = [_][]const u8{
    "x86_64-linux-gnu",
    "aarch64-linux-gnu",
    "x86_64-macos",
    "aarch64-macos",
    "x86_64-freebsd",
    "x86_64-openbsd",
    "x86_64-netbsd",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
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

    const exe_module = createRushRootModule(b, target, optimize, vaxis, zeit, build_config, use_system_sqlite, .{ .link_libc = true });
    const exe = b.addExecutable(.{
        .name = "rush",
        .root_module = exe_module,
    });

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
    const test_module = createRushRootModule(b, target, optimize, vaxis, zeit, build_config, use_system_sqlite, .{});
    const exe_tests = b.addTest(.{
        .root_module = test_module,
    });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

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
        const check_vaxis = b.dependency("vaxis", .{
            .target = check_target,
            .optimize = optimize,
        }).module("vaxis");
        const check_zeit = b.dependency("zeit", .{
            .target = check_target,
            .optimize = optimize,
        }).module("zeit");
        const check_module = createRushRootModule(
            b,
            check_target,
            optimize,
            check_vaxis,
            check_zeit,
            build_config,
            use_system_sqlite,
            .{ .link_libc = true },
        );
        const check = b.addExecutable(.{
            .name = b.fmt("rush-{s}", .{target_name}),
            .root_module = check_module,
        });
        compile_check_step.dependOn(&check.step);
    }
}

fn createRushRootModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    vaxis: *std.Build.Module,
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

fn addFuzzTarget(b: *std.Build, umbrella: *std.Build.Step, target: std.Build.ResolvedTarget, options: FuzzTargetOptions) void {
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
    tests.root_module.addImport(options.source_module_name, b.createModule(.{
        .root_source_file = b.path(options.source_module_root),
        .target = target,
        .optimize = fuzz_optimize,
        .link_libc = options.link_libc,
    }));
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
