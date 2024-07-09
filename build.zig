const std = @import("std");

const SslLibType = @import("src/crypto/ssl.zig").SslLibType;

const Compile = std.Build.Step.Compile;
const Dependency = std.Build.Dependency;

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
    const default_boringssl = !use_openssl and !use_wolfssl;
    const use_boringssl = b.option(bool, "USE_BORINGSSL", "indicates whether zSockets will use boringssl") orelse if (default_boringssl) true else false;
    const ssl_type: SslLibType = if (use_boringssl) .boringssl else if (use_openssl) .openssl else .wolfssl;

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
    shared_opts.addOption(SslLibType, "ssl_lib", ssl_type);
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

    // SSL/crypto dependencies
    const ssl_deps: SslDeps = .{
        .openssl = if (ssl_type == .openssl) b.dependency("openssl", .{ .target = target, .optimize = optimize }) else undefined,
        .wolfssl = if (ssl_type == .wolfssl) b.dependency("wolfssl", .{ .target = target, .optimize = optimize }) else undefined,
        .boringssl = if (ssl_type == .boringssl) b.dependency("boringssl", .{ .target = target, .optimize = optimize }) else undefined,
    };
    // Event loop dependencies
    const asio: *std.Build.Dependency = if (use_asio) b.dependency("asio", .{ .target = target, .optimize = optimize }) else undefined;

    const lib = b.addSharedLibrary(.{
        .name = "zSockets",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/zsockets.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibC();
    linkSsl(lib, ssl_type, ssl_deps);

    if (use_asio) {
        const libasio = asio.artifact("asio");
        lib.linkLibrary(libasio);
        lib.installLibraryHeaders(libasio);
    }
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
    linkSsl(lib_unit_tests, ssl_type, ssl_deps);

    if (use_asio) {
        const libasio = asio.artifact("asio");
        lib_unit_tests.linkLibrary(libasio);
        lib_unit_tests.installLibraryHeaders(libasio);
    }

    lib_unit_tests.root_module.addOptions("build_opts", shared_opts);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}

const SslDeps = struct {
    boringssl: *Dependency,
    openssl: *Dependency,
    wolfssl: *Dependency,
};

pub fn linkSsl(c: *Compile, ssl_type: SslLibType, deps: SslDeps) void {
    switch (ssl_type) {
        .boringssl => {
            const libboringssl = deps.boringssl.artifact("ssl");
            c.linkLibrary(libboringssl);
            c.installLibraryHeaders(libboringssl);
        },
        .openssl => {
            const libssl = deps.openssl.artifact("ssl");
            c.linkLibrary(libssl);
            c.installLibraryHeaders(libssl);
        },
        else => {
            const libwolfssl = deps.wolfssl.artifact("wolfssl");
            c.linkLibrary(libwolfssl);
            c.installLibraryHeaders(libwolfssl);
        },
    }
}
