const std = @import("std");
const utils = @import("src/utils.zig");

const EventLoopT = utils.EventLoopT;
const SslT = utils.SslT;

const Compile = std.Build.Step.Compile;
const Dependency = std.Build.Dependency;

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {

    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // ssl options
    const ssl_type = getSslT(.{
        .use_openssl = b.option(bool, "USE_OPENSSL", "indicates whether zSockets will use openssl") orelse false,
        .use_wolfssl = b.option(bool, "USE_WOLFSSL", "indicates whether zSockets will use wolfssl") orelse false,
        .use_boringssl = b.option(bool, "USE_BORINGSSL", "indicates whether zSockets will use boringssl") orelse false,
    });

    // event loop options
    var event_opts: EventLoopOpts = .{
        .use_io_uring = b.option(bool, "USE_IO_URING", "indicates whether zSockets will use io_uring") orelse false,
        .use_epoll = b.option(bool, "USE_EPOLL", "indicates whether zSockets will use epoll") orelse false,
        .use_libuv = b.option(bool, "USE_LIBUV", "indicates whether zSockets will use libuv") orelse false,
        .use_gcd = b.option(bool, "USE_GCD", "indicates whether zSockets will use GCD") orelse false,
        .use_kqueue = b.option(bool, "USE_KQUEUE", "indicates whether zSockets will use kqueue") orelse false,
        .use_asio = b.option(bool, "USE_ASIO", "indicates whether zSockets will use asio") orelse false,
    };

    // if no opts are set, default based on target
    if (!event_opts.use_io_uring and !event_opts.use_epoll and !event_opts.use_libuv and !event_opts.use_gcd and !event_opts.use_kqueue and !event_opts.use_asio) {
        const os_tag = target.result.os.tag;
        if (os_tag == .windows) {
            event_opts.use_libuv = true;
        } else if (os_tag.isDarwin() or os_tag.isBSD()) {
            event_opts.use_kqueue = true;
        } else {
            event_opts.use_epoll = true;
        }
    }
    const event_type = getEventLoopT(event_opts);
    const use_quic = b.option(bool, "USE_QUIC", "indicates whether zSockets will use QUIC") orelse false;

    var shared_opts = b.addOptions();
    shared_opts.addOption(SslT, "ssl_lib", ssl_type);
    shared_opts.addOption(EventLoopT, "event_loop_lib", event_type);
    shared_opts.addOption(bool, "USE_QUIC", use_quic);

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
    const asio: *std.Build.Dependency = if (event_type == .asio) b.dependency("asio", .{ .target = target, .optimize = optimize }) else undefined;
    const lsquic: *std.Build.Dependency = if (use_quic) b.dependency("lsquic", .{ .target = target, .optimize = optimize }) else undefined;
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

    if (event_type == .asio) {
        const libasio = asio.artifact("asio");
        lib.linkLibrary(libasio);
        lib.installLibraryHeaders(libasio);
    }
    if (use_quic) {
        const liblsquic = lsquic.artifact("lsquic");
        lib.linkLibrary(liblsquic);
        lib.installLibraryHeaders(liblsquic);
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

    if (event_type == .asio) {
        const libasio = asio.artifact("asio");
        lib_unit_tests.linkLibrary(libasio);
        lib_unit_tests.installLibraryHeaders(libasio);
    }
    if (use_quic) {
        const liblsquic = lsquic.artifact("lsquic");
        lib_unit_tests.linkLibrary(liblsquic);
        lib_unit_tests.installLibraryHeaders(liblsquic);
    }

    lib_unit_tests.root_module.addOptions("build_opts", shared_opts);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    const echo_server_exe = b.addExecutable(.{
        .name = "echo_server",
        .root_source_file = b.path("examples/echo_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    echo_server_exe.root_module.addImport("zSockets", &lib.root_module);

    const run_echo_server_exe = b.addRunArtifact(echo_server_exe);

    const run_echo_server_step = b.step("run_echo_server", "Run the echo server demo");
    run_echo_server_step.dependOn(&run_echo_server_exe.step);
}

const SslOpts = struct {
    use_openssl: bool,
    use_wolfssl: bool,
    use_boringssl: bool,
};

pub fn getSslT(opts: SslOpts) SslT {
    return if (opts.use_boringssl)
        .boringssl
    else if (opts.use_openssl)
        .openssl
    else if (opts.use_wolfssl)
        .wolfssl
    else
        .nossl;
}

const EventLoopOpts = struct {
    use_io_uring: bool,
    use_epoll: bool,
    use_libuv: bool,
    use_gcd: bool,
    use_kqueue: bool,
    use_asio: bool,
};

pub fn getEventLoopT(opts: EventLoopOpts) EventLoopT {
    return if (opts.use_io_uring)
        .io_uring
    else if (opts.use_epoll)
        .epoll
    else if (opts.use_libuv)
        .libuv
    else if (opts.use_gcd)
        .gcd
    else if (opts.use_kqueue)
        .kqueue
    else
        .asio;
}

const SslDeps = struct {
    boringssl: *Dependency,
    openssl: *Dependency,
    wolfssl: *Dependency,
};

pub fn linkSsl(c: *Compile, ssl_type: SslT, deps: SslDeps) void {
    switch (ssl_type) {
        .boringssl => {
            const libssl = deps.boringssl.artifact("ssl");
            const libcrypto = deps.boringssl.artifact("crypto");
            c.linkLibrary(libssl);
            c.linkLibrary(libcrypto);
            c.installLibraryHeaders(libssl);
        },
        .openssl => {
            const libssl = deps.openssl.artifact("ssl");
            const libcrypto = deps.openssl.artifact("crypto");
            c.linkLibrary(libssl);
            c.linkLibrary(libcrypto);
            c.installLibraryHeaders(libssl);
        },
        .wolfssl => {
            const libssl = deps.wolfssl.artifact("wolfssl");
            c.linkLibrary(libssl);
            c.installLibraryHeaders(libssl);
        },
        else => {},
    }
}
