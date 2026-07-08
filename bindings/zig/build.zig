const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const nexaloid = b.createModule(.{
        .root_source_file = b.path("nexaloid.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    nexaloid.addIncludePath(b.path("../../core/include"));

    const regression = b.addExecutable(.{
        .name = "nexaloid-zig-regression",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/regression.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    regression.root_module.addImport("nexaloid", nexaloid);
    regression.root_module.addLibraryPath(b.path("../../core/zig-out/lib"));
    regression.root_module.linkSystemLibrary("nexaloid", .{});

    const run_regression = b.addRunArtifact(regression);
    run_regression.addPathDir("../../core/zig-out/bin");
    const regression_step = b.step("regression", "Run Zig SDK regression");
    regression_step.dependOn(&run_regression.step);
}
