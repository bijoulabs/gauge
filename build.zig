const std = @import("std");

/// Mirrors build.zig.zon so the manifest can be imported as ZON: the version
/// lives in exactly one place and `--version` can never drift from it.
const Manifest = struct {
    name: enum { gauge },
    version: []const u8,
    minimum_zig_version: []const u8,
    fingerprint: u64,
    paths: []const []const u8,
};
const manifest: Manifest = @import("build.zig.zon");

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
    // Feeds the manifest version into src/main.zig's `--version` output; the
    // tests reuse exe.root_module, so the option reaches them for free.
    const options = b.addOptions();
    options.addOption([]const u8, "version", manifest.version);
    exe.root_module.addOptions("build_options", options);
    b.installArtifact(exe);

    const tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
