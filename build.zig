const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "gauge",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // NOTE: state.zig reads environment variables via libc's `environ`
            // global (see the reconciliation note in src/state.zig): this Zig
            // version's std.process has no standalone env accessor outside the
            // Init-threaded Environ API, which stateDirPath's committed
            // signature has no room for.
            .link_libc = true,
        }),
    });
    b.installArtifact(exe);

    const tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
