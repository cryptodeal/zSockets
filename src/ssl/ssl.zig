const build_opts = @import("build_opts");
const internal = @import("../internal/internal.zig");
pub const ssl = if (build_opts.USE_OPENSSL) @import("openssl.zig") else if (build_opts.USE_WOLFSSL) @import("wolfssl.zig") else undefined;

const Socket = internal.Socket;

// TODO(cryptodeal): purge c types in favor of zig primitives
pub const LoopSslData = struct {
    ssl_read_input: []u8,
    ssl_read_output: []u8,
    ssl_socket: *Socket,
    last_write_was_msg_more: c_int,
    msg_more: c_int,
    shared_rbio: *ssl.Bio,
    shared_wbio: *ssl.Bio,
    shared_biom: *ssl.BioMethod,
};
