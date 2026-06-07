const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "rush",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

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
        }),
    });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

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
}
