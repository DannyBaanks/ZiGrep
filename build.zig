const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zgrep",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // Also install under the official name "zigrep"
    const zigrep_exe = b.addExecutable(.{
        .name = "zigrep",
        .root_module = exe.root_module,
    });
    b.installArtifact(zigrep_exe);

    // The matcher sweep imports src/search.zig directly (as an anonymous
    // import), so it can never drift from the matchers the binary ships.
    const sweep_mod = b.createModule(.{
        .root_source_file = b.path("scripts/matcher_sweep.zig"),
        .target = target,
        .optimize = optimize,
    });
    sweep_mod.addAnonymousImport("matcher", .{
        .root_source_file = b.path("src/search.zig"),
        .target = target,
        .optimize = optimize,
    });
    sweep_mod.addAnonymousImport("walk", .{
        .root_source_file = b.path("src/walk.zig"),
        .target = target,
        .optimize = optimize,
    });
    const sweep_exe = b.addExecutable(.{ .name = "matcher_sweep", .root_module = sweep_mod });
    b.installArtifact(sweep_exe);
    const sweep_run = b.addRunArtifact(sweep_exe);
    sweep_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| sweep_run.addArgs(args);
    const sweep_step = b.step("sweep", "Run the bmh vs memchr crossover sweep");
    sweep_step.dependOn(&sweep_run.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run zgrep");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run zgrep unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
