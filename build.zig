const std = @import("std");

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
    linkSqlite(b, exe.root_module, use_system_sqlite);

    b.installArtifact(exe);
    b.installDirectory(.{
        .source_dir = b.path("share/rush/completions"),
        .install_dir = .{ .custom = "share/rush/completions" },
        .install_subdir = "",
        .include_extensions = &.{".rush"},
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
    });
    linkSqlite(b, exe_tests.root_module, use_system_sqlite);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    const compile_test_step = b.step("compile-test", "Compile unit tests without running them");
    compile_test_step.dependOn(&exe_tests.step);

    const fmt_step = b.step("fmt", "Check code formatting");
    const fmt_check = b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" }, .check = true });
    fmt_step.dependOn(&fmt_check.step);
    test_step.dependOn(fmt_step);

    const cross_check_step = b.step("cross-check", "Run native tests and compile-check Linux/macOS/BSD targets");
    const cross_check = b.addSystemCommand(&.{ "sh", "scripts/check-cross-targets.sh" });
    cross_check.step.dependOn(fmt_step);
    cross_check_step.dependOn(&cross_check.step);

    const corpus_step = b.step("corpus", "Compare supported behavior corpus against available system shells");
    const corpus_check = b.addSystemCommand(&.{ "sh", "scripts/check-system-shell-corpus.sh" });
    corpus_check.step.dependOn(&exe.step);
    corpus_check.step.dependOn(fmt_step);
    corpus_step.dependOn(&corpus_check.step);

    const posix_corpus_step = b.step("posix-corpus", "Run spec-derived POSIX expected-output corpus");
    const posix_corpus_check = b.addSystemCommand(&.{ "sh", "scripts/check-posix-corpus.sh" });
    posix_corpus_check.step.dependOn(&exe.step);
    posix_corpus_check.step.dependOn(fmt_step);
    posix_corpus_step.dependOn(&posix_corpus_check.step);

    const compliance_manifest_step = b.step("compliance-manifest", "Validate POSIX compliance manifest schema and references");
    const compliance_manifest_check = b.addSystemCommand(&.{ "sh", "scripts/check-compliance-manifest.sh" });
    compliance_manifest_check.step.dependOn(fmt_step);
    compliance_manifest_step.dependOn(&compliance_manifest_check.step);

    const posix_negative_corpus_step = b.step("posix-negative-corpus", "Run POSIX negative diagnostics corpus");
    const posix_negative_corpus_check = b.addSystemCommand(&.{ "sh", "scripts/check-posix-negative-corpus.sh" });
    posix_negative_corpus_check.step.dependOn(&exe.step);
    posix_negative_corpus_check.step.dependOn(fmt_step);
    posix_negative_corpus_step.dependOn(&posix_negative_corpus_check.step);

    const compliance_step = b.step("compliance", "Report POSIX compliance metrics and validate corpora");
    const compliance_report = b.addSystemCommand(&.{ "sh", "scripts/report-compliance.sh", "--run-corpora" });
    compliance_report.step.dependOn(&exe.step);
    compliance_report.step.dependOn(fmt_step);
    compliance_step.dependOn(&compliance_report.step);
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
    module.addCSourceFile(.{
        .file = sqlite.path("sqlite3.c"),
        .flags = &.{
            "-DSQLITE_ENABLE_FTS5",
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_DEFAULT_MEMSTATUS=0",
        },
    });
    module.addIncludePath(sqlite.path("."));
    module.link_libc = true;
}
