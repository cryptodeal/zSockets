const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {

    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // ssl options
    const use_openssl = b.option(bool, "USE_OPENSSL", "indicates whether zSockets will use openssl") orelse false;
    const use_wolfssl = b.option(bool, "USE_WOLFSSL", "indicates whether zSockets will use wolfssl") orelse false;
    // event loop options
    const use_io_uring = b.option(bool, "USE_IO_URING", "indicates whether zSockets will use io_uring") orelse false;
    var use_epoll = b.option(bool, "USE_EPOLL", "indicates whether zSockets will use epoll") orelse false;
    var use_libuv = b.option(bool, "USE_LIBUV", "indicates whether zSockets will use libuv") orelse false;
    const use_gcd = b.option(bool, "USE_GCD", "indicates whether zSockets will use GCD") orelse false;
    var use_kqueue = b.option(bool, "USE_KQUEUE", "indicates whether zSockets will use kqueue") orelse false;
    const use_asio = b.option(bool, "USE_ASIO", "indicates whether zSockets will use asio") orelse false;
    // if no opts are set, default based on target
    if (!use_io_uring and !use_epoll and !use_libuv and !use_gcd and !use_kqueue and !use_asio) {
        const os_tag = target.result.os.tag;
        if (os_tag == .windows) {
            use_libuv = true;
        } else if (os_tag.isDarwin() or os_tag.isBSD()) {
            use_kqueue = true;
        } else {
            use_epoll = true;
        }
    }
    var shared_opts = b.addOptions();
    shared_opts.addOption(bool, "USE_OPENSSL", use_openssl);
    shared_opts.addOption(bool, "USE_WOLFSSL", use_wolfssl);
    shared_opts.addOption(bool, "USE_IO_URING", use_io_uring);
    shared_opts.addOption(bool, "USE_EPOLL", use_epoll);
    shared_opts.addOption(bool, "USE_LIBUV", use_libuv);
    shared_opts.addOption(bool, "USE_GCD", use_gcd);
    shared_opts.addOption(bool, "USE_KQUEUE", use_kqueue);
    shared_opts.addOption(bool, "USE_ASIO", use_asio);

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // dependencies
    const openssl: *std.Build.Dependency = if (use_openssl) b.dependency("openssl", .{ .target = target, .optimize = optimize }) else undefined;
    // TODO(cryptodeal): get `wolfssl` to build/link
    // const wolfssl: *std.Build.Dependency = if (use_wolfssl) b.dependency("wolfssl", .{ .target = target, .optimize = optimize }) else undefined;

    const lib = b.addStaticLibrary(.{
        .name = "zSockets",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/zsockets.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibC();
    if (use_openssl) lib.linkLibrary(openssl.artifact("ssl"));
    // if (use_wolfssl) lib.linkLibrary(wolfssl.artifact("wolfssl"));

    lib.root_module.addOptions("build_opts", shared_opts);

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/zsockets.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_unit_tests.linkLibC();
    if (use_openssl) lib_unit_tests.linkLibrary(openssl.artifact("ssl"));
    // if (use_wolfssl) lib_unit_tests.linkLibrary(wolfssl.artifact("wolfssl"));

    lib_unit_tests.root_module.addOptions("build_opts", shared_opts);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
