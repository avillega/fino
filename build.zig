const std = @import("std");

const Kind = enum { moar_smaller, post_tree, forest_pointer, index_sea };

fn finoModule(b: *std.Build, target: std.Build.ResolvedTarget, opts_mod: *std.Build.Module) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    mod.addImport("build_opts", opts_mod);
    return mod;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const kind = b.option(Kind, "kind", "Which parser implementation to build") orelse .post_tree;
    const opts = b.addOptions();
    opts.addOption(Kind, "kind", kind);
    const opts_mod = opts.createModule();

    const fino_mod = finoModule(b, target, opts_mod);

    const exe = b.addExecutable(.{
        .name = "fino",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "fino", .module = fino_mod },
            },
        }),
    });
    exe.root_module.addImport("build_opts", opts_mod);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = fino_mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const bench_step = b.step("bench", "Benchmark all parser variants with /usr/bin/time -l and hyperfine and measures ast size");
    var prev_run: ?*std.Build.Step = null;

    const hyperfine = b.addSystemCommand(&.{ "hyperfine", "--warmup", "5", "-N" });
    hyperfine.stdio = .inherit;
    hyperfine.has_side_effects = true;

    for ([_]Kind{ .moar_smaller, .post_tree, .forest_pointer, .index_sea }) |k| {
        const kopts = b.addOptions();
        kopts.addOption(Kind, "kind", k);
        const kopts_mod = kopts.createModule();
        const bench_exe = bench(b, target, &prev_run, bench_step, kopts_mod);

        const name = b.fmt("fino-{s}", .{@tagName(k)});
        const install = b.addInstallArtifact(bench_exe, .{ .dest_sub_path = name });
        hyperfine.step.dependOn(&install.step);
        hyperfine.addArgs(&.{
            "-n",
            @tagName(k),
            b.fmt("{s} {s} -bench", .{
                b.getInstallPath(.bin, name),
                b.pathFromRoot("examples/bench.fino"),
            }),
        });
    }

    if (prev_run) |p| hyperfine.step.dependOn(p);
    bench_step.dependOn(&hyperfine.step);
}

fn bench(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    prev_run: *?*std.Build.Step,
    bench_step: *std.Build.Step,
    opts_mod: *std.Build.Module,
) *std.Build.Step.Compile {
    const fino_mod = finoModule(b, target, opts_mod);
    const exe = b.addExecutable(.{
        .name = "fino",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = std.builtin.OptimizeMode.ReleaseFast,
            .imports = &.{
                .{ .name = "fino", .module = fino_mod },
            },
        }),
    });
    exe.root_module.addImport("build_opts", opts_mod);

    const size = b.addRunArtifact(exe);
    size.addFileArg(b.path("examples/bench.fino"));
    size.addArg("-astsize");
    size.stdio = .inherit;
    size.has_side_effects = true;
    if (prev_run.*) |p| size.step.dependOn(p);

    const run = b.addSystemCommand(&.{ "/usr/bin/time", "-l", "-h" });
    run.addArtifactArg(exe);
    run.addFileArg(b.path("examples/bench.fino"));
    run.addArg("-bench");
    run.stdio = .inherit;
    run.has_side_effects = true;
    run.step.dependOn(&size.step);

    prev_run.* = &run.step;
    bench_step.dependOn(&run.step);

    return exe;
}
