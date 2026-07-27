const std = @import("std");
const build_helpers = @import("src/internal/build_helpers.zig");

const EventBackend = build_helpers.EventBackend;
const SslType = build_helpers.SslType;

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) !void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    const options = b.addOptions();
    // TODO: implement the following event loop backends, which makes these options relevant.
    const event_backend = EventBackend.fromBuildOptions(.{
        .with_io_uring = b.option(bool, "WITH_IO_URING", "builds with io_uring as event-loop and network implementation") orelse false,
        .with_libuv = b.option(bool, "WITH_LIBUV", "builds with libuv as event-loop") orelse false,
        .with_asio = b.option(bool, "WITH_ASIO", "builds with boot ASIO as event-loop") orelse false,
        .with_gcd = b.option(bool, "WITH_GCD", "builds with libdispatch as event-loop") orelse false,
        .with_epoll = b.option(bool, "WITH_EPOLL", "builds with epoll as event-loop") orelse false,
        .with_kqueue = b.option(bool, "WITH_KQUEUE", "builds with kqueue as event-loop") orelse false,
    }, target.result);
    options.addOption(EventBackend, "event_backend", event_backend);

    // Use Quic for networking.
    const with_quic = b.option(bool, "WITH_QUIC", "builds with QUIC network implementation") orelse false;
    options.addOption(bool, "with_quic", with_quic);

    // TODO: implement SSL options
    const ssl_impl = SslType.fromBuildOptions(.{
        .with_boringssl = b.option(bool, "WITH_BORINGSSL", "enables BoringSSL support, linked statically (preferred over OpenSSL)") orelse false,
        .with_openssl = b.option(bool, "WITH_OPENSSL", "enables OpenSSL 1.1+ support") orelse false,
        .with_wolfssl = b.option(bool, "WITH_WOLFSSL", "enables WolfSSL 4.2.0 support (mutually exclusive with OpenSSL)") orelse false,
    });
    // TODO: link to selected SSL library
    options.addOption(SslType, "ssl_impl", ssl_impl);

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("zSockets", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
        .link_libc = true,
    });

    if (with_quic) {
        if (b.lazyDependency("lsquic", .{ .target = target, .optimize = optimize })) |lsquic_dep| {
            mod.addCSourceFile(.{
                .file = b.path("src/quic.c"),
            });
            const lib_lsquic = lsquic_dep.artifact("lsquic");
            const translate_c = b.addTranslateC(.{
                .root_source_file = b.path("src/quic.h"),
                .target = target,
                .optimize = optimize,
            });
            translate_c.addIncludePath(lib_lsquic.getEmittedIncludeTree());
            mod.addImport("lsquic", translate_c.createModule());
            mod.linkLibrary(lib_lsquic);
        }
    }

    switch (event_backend) {
        .libuv => if (b.lazyDependency("libuv", .{ .target = target, .optimize = optimize })) |libuv_dep| {
            const libuv = libuv_dep.artifact("uv");
            // Darwin has compile errors due to checks of opaque type size in translated header
            // use hardcoded translation modified to work
            if (!target.result.os.tag.isDarwin()) {
                const translate_c = b.addTranslateC(.{
                    .root_source_file = b.path("src/eventing/libuv/libuv.h"),
                    .target = target,
                    .optimize = optimize,
                });
                translate_c.addIncludePath(libuv.getEmittedIncludeTree());
                mod.addImport("libuv", translate_c.createModule());
            }
            mod.linkLibrary(libuv);
        },
        .gcd => mod.linkFramework("CoreFoundation", .{}),
        // TODO: link asio
        else => {},
    }

    switch (ssl_impl) {
        .boringssl => if (b.lazyDependency("boringssl", .{ .target = target, .optimize = optimize })) |boringssl_dep| {
            const translate_c = b.addTranslateC(.{
                .root_source_file = b.path("src/crypto/openssl.h"),
                .target = target,
                .optimize = optimize,
            });
            translate_c.defineCMacro("USE_BORINGSSL", null);
            const libssl = boringssl_dep.artifact("ssl");
            const libcrypto = boringssl_dep.artifact("crypto");
            translate_c.addIncludePath(libssl.getEmittedIncludeTree());
            translate_c.addIncludePath(libcrypto.getEmittedIncludeTree());
            mod.linkLibrary(libssl);
            mod.linkLibrary(libcrypto);
            mod.addImport("openssl", translate_c.createModule());
        },
        .openssl => if (b.lazyDependency("openssl", .{ .target = target, .optimize = optimize })) |openssl_dep| {
            const translate_c = b.addTranslateC(.{
                .root_source_file = b.path("src/crypto/openssl.h"),
                .target = target,
                .optimize = optimize,
            });

            const libssl = openssl_dep.artifact("ssl");
            const libcrypto = openssl_dep.artifact("crypto");
            translate_c.addIncludePath(libssl.getEmittedIncludeTree());
            translate_c.addIncludePath(libcrypto.getEmittedIncludeTree());
            mod.linkLibrary(libssl);
            mod.linkLibrary(libcrypto);
            mod.addImport("openssl", translate_c.createModule());
        },
        // TODO: support wolfssl
        // .wolfssl =>
        else => {},
    }
    mod.addOptions("build_opts", options);

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const echo_server_exe = b.addExecutable(.{
        .name = "echo_server",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("examples/echo_server.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "zSockets" is the name you will use in your source code to
                // import this module (e.g. `@import("zSockets")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "zSockets", .module = mod },
            },
        }),
    });

    const tcp_server_exe = b.addExecutable(.{
        .name = "tcp_server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/tcp_server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zSockets", .module = mod },
            },
        }),
    });

    const hammer_test_unix_exe = b.addExecutable(.{
        .name = "hammer_test_unix",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/hammer_test_unix.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zSockets", .module = mod },
            },
        }),
    });

    const hammer_test_exe = b.addExecutable(.{
        .name = "hammer_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/hammer_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zSockets", .module = mod },
            },
        }),
    });

    const http_load_test_exe = b.addExecutable(.{
        .name = "http_load_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/http_load_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zSockets", .module = mod },
                .{ .name = "args", .module = b.dependency("args", .{ .target = target, .optimize = optimize }).module("args") },
            },
        }),
    });

    const http_server_exe = b.addExecutable(.{
        .name = "http_server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/http_server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zSockets", .module = mod },
            },
        }),
    });

    const tcp_load_test_exe = b.addExecutable(.{
        .name = "tcp_load_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/tcp_load_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zSockets", .module = mod },
                .{ .name = "args", .module = b.dependency("args", .{ .target = target, .optimize = optimize }).module("args") },
            },
        }),
    });

    const udp_benchmark_exe = b.addExecutable(.{
        .name = "udp_benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/udp_benchmark.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zSockets", .module = mod },
                .{ .name = "args", .module = b.dependency("args", .{ .target = target, .optimize = optimize }).module("args") },
            },
        }),
    });

    const http3_client_exe = b.addExecutable(.{
        .name = "http3_client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/http3_client.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zSockets", .module = mod },
            },
        }),
    });

    const http3_server_exe = b.addExecutable(.{
        .name = "http3_server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/http3_server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zSockets", .module = mod },
            },
        }),
    });

    const peer_verify_test_exe = b.addExecutable(.{
        .name = "peer_verify_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/peer_verify_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zSockets", .module = mod },
            },
        }),
    });

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const echo_server_run_step = b.step("echo_server", "Run the echo_server example");
    const tcp_server_run_step = b.step("tcp_server", "Run the tcp_server example");
    const hammer_test_unix_run_step = b.step("hammer_test_unix", "Run the hammer_test_unix example");
    const hammer_test_run_step = b.step("hammer_test", "Run the hammer_test example");
    const http_load_test_run_step = b.step("http_load_test", "Run the http_load_test example");
    const http_server_run_step = b.step("http_server", "Run the http_server example");
    const tcp_load_test_run_step = b.step("tcp_load_test", "Run the tcp_load_test example");
    const udp_benchmark_run_step = b.step("udp_benchmark", "Run the udp_benchmark example");
    const http3_client_run_step = b.step("http3_client", "Run the http3_client example");
    const http3_server_run_step = b.step("http3_server", "Run the http3_server example");
    const peer_verify_test_run_step = b.step("peer_verify_test", "Run the peer_verify_test example");

    // This creates an InstallArtifact step in the build graph. An InstallArtifact
    // step declares intent for the executable to be installed into the install prefix
    // when running `zig build step_name`.
    const echo_server_install_cmd = b.addInstallArtifact(echo_server_exe, .{});
    echo_server_run_step.dependOn(&echo_server_install_cmd.step);

    const tcp_server_install_cmd = b.addInstallArtifact(tcp_server_exe, .{});
    tcp_server_run_step.dependOn(&tcp_server_install_cmd.step);

    const hammer_test_unix_install_cmd = b.addInstallArtifact(hammer_test_unix_exe, .{});
    hammer_test_unix_run_step.dependOn(&hammer_test_unix_install_cmd.step);

    const hammer_test_install_cmd = b.addInstallArtifact(hammer_test_exe, .{});
    hammer_test_run_step.dependOn(&hammer_test_install_cmd.step);

    const http_load_test_install_cmd = b.addInstallArtifact(http_load_test_exe, .{});
    http_load_test_run_step.dependOn(&http_load_test_install_cmd.step);

    const http_server_install_cmd = b.addInstallArtifact(http_server_exe, .{});
    http_server_run_step.dependOn(&http_server_install_cmd.step);

    const tcp_load_test_install_cmd = b.addInstallArtifact(tcp_load_test_exe, .{});
    tcp_load_test_run_step.dependOn(&tcp_load_test_install_cmd.step);

    const udp_benchmark_install_cmd = b.addInstallArtifact(udp_benchmark_exe, .{});
    udp_benchmark_run_step.dependOn(&udp_benchmark_install_cmd.step);

    const http3_client_install_cmd = b.addInstallArtifact(http3_client_exe, .{});
    http3_client_run_step.dependOn(&http3_client_install_cmd.step);

    const http3_server_install_cmd = b.addInstallArtifact(http3_server_exe, .{});
    http3_server_run_step.dependOn(&http3_server_install_cmd.step);

    const peer_verify_test_install_cmd = b.addInstallArtifact(peer_verify_test_exe, .{});
    peer_verify_test_run_step.dependOn(&peer_verify_test_install_cmd.step);

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const echo_server_run_cmd = b.addRunArtifact(echo_server_exe);
    echo_server_run_step.dependOn(&echo_server_run_cmd.step);

    const tcp_server_run_cmd = b.addRunArtifact(tcp_server_exe);
    tcp_server_run_step.dependOn(&tcp_server_run_cmd.step);

    const hammer_test_unix_run_cmd = b.addRunArtifact(hammer_test_unix_exe);
    hammer_test_unix_run_step.dependOn(&hammer_test_unix_run_cmd.step);

    const hammer_test_run_cmd = b.addRunArtifact(hammer_test_exe);
    hammer_test_run_step.dependOn(&hammer_test_run_cmd.step);

    const http_load_test_run_cmd = b.addRunArtifact(http_load_test_exe);
    http_load_test_run_step.dependOn(&http_load_test_run_cmd.step);

    const http_server_run_cmd = b.addRunArtifact(http_server_exe);
    http_server_run_step.dependOn(&http_server_run_cmd.step);

    const tcp_load_test_run_cmd = b.addRunArtifact(tcp_load_test_exe);
    tcp_load_test_run_step.dependOn(&tcp_load_test_run_cmd.step);

    const udp_benchmark_run_cmd = b.addRunArtifact(udp_benchmark_exe);
    udp_benchmark_run_step.dependOn(&udp_benchmark_run_cmd.step);

    const http3_client_run_cmd = b.addRunArtifact(http3_client_exe);
    http3_client_run_step.dependOn(&http3_client_run_cmd.step);

    const http3_server_run_cmd = b.addRunArtifact(http3_server_exe);
    http3_server_run_step.dependOn(&http3_server_run_cmd.step);

    const peer_verify_test_run_cmd = b.addRunArtifact(peer_verify_test_exe);
    peer_verify_test_run_step.dependOn(&peer_verify_test_run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    echo_server_run_cmd.step.dependOn(b.getInstallStep());
    tcp_server_run_cmd.step.dependOn(b.getInstallStep());
    hammer_test_unix_run_cmd.step.dependOn(b.getInstallStep());
    hammer_test_run_cmd.step.dependOn(b.getInstallStep());
    http_load_test_run_cmd.step.dependOn(b.getInstallStep());
    http_server_run_cmd.step.dependOn(b.getInstallStep());
    tcp_load_test_run_cmd.step.dependOn(b.getInstallStep());
    udp_benchmark_run_cmd.step.dependOn(b.getInstallStep());
    http3_client_run_cmd.step.dependOn(b.getInstallStep());
    http3_server_run_cmd.step.dependOn(b.getInstallStep());
    peer_verify_test_run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        echo_server_run_cmd.addArgs(args);
        tcp_server_run_cmd.addArgs(args);
        hammer_test_unix_run_cmd.addArgs(args);
        hammer_test_run_cmd.addArgs(args);
        http_load_test_run_cmd.addArgs(args);
        http_server_run_cmd.addArgs(args);
        tcp_load_test_run_cmd.addArgs(args);
        udp_benchmark_run_cmd.addArgs(args);
        http3_client_run_cmd.addArgs(args);
        http3_server_run_cmd.addArgs(args);
        peer_verify_test_run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
