const context = @import("context.zig");
pub const ssl = @import("crypto/ssl.zig");

pub const Loop = @import("loop.zig").Loop;
pub const Socket = @import("internal/internal.zig").Socket;
pub const SocketCtx = context.SocketCtx;
pub const SocketCtxOpts = context.SocketCtxOpts;

/// Options specifying ownership of port.
pub const PortOptions = enum {
    /// Default port options.
    default,
    /// Port is owned by zSocket and will not be shared.
    exclusive_port,
};

test {
    const refAllDecls = @import("std").testing.refAllDecls;
    const refAllDeclsRecursive = @import("std").testing.refAllDeclsRecursive;

    // Note we can't recursively import Shape.zig because otherwise we try to compile
    // std.BoundedArray(i64).Writer, which fails.
    refAllDecls(@import("crypto/sni_tree.zig"));
    refAllDeclsRecursive(@import("loop.zig"));
    // refAllDecls(ssl);
}
