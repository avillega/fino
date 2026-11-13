const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const menu = .{
        .run = b.step("run", "runs fino"),
        .@"test" = b.step("test", "run tests"),
        .check = b.step("check", "check it compiles"),
    };
    b.default_step = menu.run;

    const test_filters = b.option(
        []const []const u8,
        "filter",
        "Skip tests that do not match any filter",
    ) orelse &[0][]const u8{};

    const tests = b.addTest(.{
        .filters = test_filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    run_tests.has_side_effects = true;
    menu.@"test".dependOn(&run_tests.step);

    const exe = b.addExecutable(.{
        .name = "fino",
        .root_module = b.createModule(.{
            .strip = false,
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    menu.check.dependOn(&tests.step);
    menu.check.dependOn(&exe.step);

    const run_exe = b.addRunArtifact(exe);
    run_exe.addPassthruArgs();
    menu.run.dependOn(&run_exe.step);

    b.installArtifact(exe);
}
