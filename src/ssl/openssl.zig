// const Socket = @import("../")

pub const openssl = @cImport({
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/bio.h");
    @cInclude("openssl/err.h");
    @cInclude("openssl/dh.h");
});

// pub const LoopSslData = struct {
//     ssl_read_input: []u8,
//     ssl_read_output: []u8,
//     ssl_read_input_offset: c_uint,
//     ssl_socket: *Socket,
// };
