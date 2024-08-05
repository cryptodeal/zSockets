const build_opts = @import("build_opts");

const ssl = switch (build_opts.ssl_lib) {
    .openssl => @import("ssl/openssl.zig"),
    .wolfssl => @import("ssl/wolfssl.zig"),
    else => @import("ssl/boringssl.zig"), // default to boringssl
};
