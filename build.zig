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

    const oracle_exe = b.addExecutable(.{
        .name = "oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/oracle.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_oracle = b.addRunArtifact(oracle_exe);
    run_oracle.step.dependOn(b.getInstallStep());
    const oracle_step = b.step("oracle", "Run differential oracle tests against GNU grep and ripgrep");
    oracle_step.dependOn(&run_oracle.step);

    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("scripts/fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_mod.addAnonymousImport("zgrep", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fuzz_exe = b.addExecutable(.{ .name = "fuzz", .root_module = fuzz_mod });
    b.installArtifact(fuzz_exe);
    const fuzz_run = b.addRunArtifact(fuzz_exe);
    fuzz_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| fuzz_run.addArgs(args);
    const fuzz_step = b.step("fuzz", "Run the adversarial entropic fuzzer swarm");
    fuzz_step.dependOn(&fuzz_run.step);

    const cell_mod = b.createModule(.{
        .root_source_file = b.path("scripts/cell_fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });
    cell_mod.addAnonymousImport("zgrep", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cell_exe = b.addExecutable(.{ .name = "cell_fuzz", .root_module = cell_mod });
    b.installArtifact(cell_exe);
    const cell_run = b.addRunArtifact(cell_exe);
    cell_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| cell_run.addArgs(args);
    const cell_step = b.step("cell-fuzz", "Run the N-dimensional discrete cell space fuzzer");
    cell_step.dependOn(&cell_run.step);
}
