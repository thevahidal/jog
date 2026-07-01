const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "jog",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Bundled plugin scripts embedded into the binary so it is self-contained.
    // They are embedded by import name (see src/bootstrap.zig).
    const bundled_plugins = [_][]const u8{
        "jog-standup",
        "jog-loose-ends",
        "jog-code-todos",
        "jog-github",
        "jog-jira",
        "jog-odoo",
        "jog-gitlab",
        "jog-linear",
        "jog-calendar",
        "jog-docker",
        "jog-pagerduty",
    };
    for (bundled_plugins) |name| {
        exe.root_module.addAnonymousImport(name, .{
            .root_source_file = b.path(b.fmt("plugins/{s}", .{name})),
        });
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run jog");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
