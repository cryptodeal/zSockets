const build_opts = @import("build_opts");
const internal = @import("../internal/internal.zig");
pub const ssl = if (build_opts.USE_OPENSSL) @import("openssl.zig") else if (build_opts.USE_WOLFSSL) @import("wolfssl.zig") else undefined;
const std = @import("std");

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

pub const InternalSslSocketCtx = struct {
    // sc: SocketCtx,

    // this thing can be shared with other socket contexts via socket transfer!
    // maybe instead of holding once you hold many, a vector or set
    // when a socket that belongs to another socket context transfers to a new socket context
    ssl_ctx: *ssl.SslCtx,
    is_parent: c_int,

    // TODO(cryptodeal): implement function pointers
    // These decorate the base implementation
    // struct us_internal_ssl_socket_t *(*on_open)(struct us_internal_ssl_socket_t *, int is_client, char *ip, int ip_length);
    // struct us_internal_ssl_socket_t *(*on_data)(struct us_internal_ssl_socket_t *, char *data, int length);
    // struct us_internal_ssl_socket_t *(*on_writable)(struct us_internal_ssl_socket_t *);
    // struct us_internal_ssl_socket_t *(*on_close)(struct us_internal_ssl_socket_t *, int code, void *reason);

    // Called for missing SNI hostnames, if not `null`
    // void (*on_server_name)(struct us_internal_ssl_socket_context_t *, const char *hostname);

    // Pointer to sni tree, created when the context is created and freed likewise when freed
    sni: ?*anyopaque,
};

// TODO:(cryptodeal): possible remove `s` field from below struct
// TODO:(cryptodeal): purge c types in favor of zig primitives
pub const InternalSslSocket = struct {
    s: Socket,
    ssl: *ssl.Ssl,
    ssl_write_wants_read: c_int,
    ssl_read_wants_write: c_int,
};

pub fn passphraseCb(buf: []u8, rwflag: c_int, u: ?*anyopaque) c_int {
    _ = rwflag; // autofix
    const passphrase: []const u8 = std.mem.span(@as([@ptrCast(@alignCast(u)));
    @memcpy(buf[0..passphrase.len], passphrase);
    // put null at end? no?
    return @intCast(passphrase.len);
}

pub fn bioSCustomCreate(bio: *ssl.Bio) c_int {
    ssl.bioSetInit(bio, 1);
    return 1;
}

// pub fn bioSCustomCtrl(bio: *ssl.Bio, cmd: c_int, num: c_long, user: ?*anyopaque) c_long {}
