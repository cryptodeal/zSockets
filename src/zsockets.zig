pub const ssl = @import("crypto/ssl.zig");

/// 512kb shared receive buffer.
pub const RECV_BUFFER_LENGTH = 524288;
/// Timeout granularity specifies +/- 4 seconds from set timeout.
pub const TIMEOUT_GRANULARITY = 4;
/// 32 byte padding of receive buffer ends.
pub const RECV_BUFFER_PADDING = 32;
/// Guaranteed alignment of extension memory.
pub const EXT_ALIGNMENT = 16;

/// Options specifying ownership of port.
pub const PortOptions = enum {
    /// Default port options.
    default,
    /// Port is owned by zSocket and will not be shared.
    exclusive_port,
};

/// Options for socket contexts.
pub const SocketCtxOpts = struct {
    key_file_path: []const u8,
    cert_file_path: []const u8,
    passphrase: []const u8,
    dh_params_file_path: []const u8,
    ca_file_path: []const u8,
    ssl_ciphers: []const u8,
    ssl_prefer_low_mem_usg: bool, // TODO: rename field/apply to TCP as well
};

test {
    const refAllDecls = @import("std").testing.refAllDecls;
    const refAllDeclsRecursive = @import("std").testing.refAllDeclsRecursive;

    // Note we can't recursively import Shape.zig because otherwise we try to compile
    // std.BoundedArray(i64).Writer, which fails.
    refAllDecls(@import("crypto/sni_tree.zig"));
    refAllDeclsRecursive(@import("quic.zig"));
}
