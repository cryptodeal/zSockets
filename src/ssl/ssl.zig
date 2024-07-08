const build_opts = @import("build_opts");
const internal = @import("../internal/internal.zig");
const ssl = if (build_opts.USE_OPENSSL) @import("openssl.zig") else if (build_opts.USE_WOLFSSL) @import("wolfssl.zig") else undefined;
const std = @import("std");

const Socket = internal.Socket;

// TODO(cryptodeal): purge c types in favor of zig primitives
pub const LoopSslData = struct {
    ssl_read_input: []u8,
    ssl_read_input_length: usize,
    ssl_read_input_offset: usize,
    ssl_socket: *Socket,
    last_write_was_msg_more: bool,
    msg_more: bool,
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
    is_parent: bool,

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
    ssl_write_wants_read: bool,
    ssl_read_wants_write: bool,
};

pub fn passphraseCb(buf: []u8, rwflag: c_int, u: ?*anyopaque) c_int {
    _ = rwflag; // autofix
    const passphrase: []const u8 = std.mem.span(@as([*c]u8, @ptrCast(@alignCast(u))));
    @memcpy(buf[0..passphrase.len], passphrase);
    // put null at end? no?
    return @intCast(passphrase.len);
}

pub fn bioSCustomCreate(bio: *ssl.Bio) c_int {
    ssl.bioSetInit(bio, 1);
    return 1;
}

pub const BioCtrlType = enum(c_int) {
    reset = ssl.c.BIO_CTRL_RESET,
    eof = ssl.c.BIO_CTRL_EOF,
    info = ssl.c.BIO_CTRL_INFO,
    set = ssl.c.BIO_CTRL_SET,
    get = ssl.c.BIO_CTRL_GET,
    push = ssl.c.BIO_CTRL_PUSH,
    pop = ssl.c.BIO_CTRL_POP,
    get_close = ssl.c.BIO_CTRL_GET_CLOSE,
    set_close = ssl.c.BIO_CTRL_SET_CLOSE,
    pending = ssl.c.BIO_CTRL_PENDING,
    flush = ssl.c.BIO_CTRL_FLUSH,
    dup = ssl.c.BIO_CTRL_DUP,
    wpending = ssl.c.BIO_CTRL_WPENDING,
};

pub fn bioSCustomCtrl(bio: *ssl.Bio, cmd: BioCtrlType, num: c_long, user: ?*anyopaque) c_long {
    _ = bio; // autofix
    _ = num; // autofix
    _ = user; // autofix
    return switch (cmd) {
        .flush => 1,
        else => 0,
    };
}

// pub fn bioSCustomWrite(bio: *ssl.Bio, data: []const u8) c_int {
//     const loop_ssl_data: *LoopSslData = @ptrCast(@alignCast(ssl.bioGetData(bio)));
//     std.log.debug("bioSCustomWrite", .{});
//     loop_ssl_data.last_write_was_msg_more = loop_ssl_data.msg_more or data.len == 16413;
//     // TODO(cryptodeal): finish implementing
// }

pub fn bioSCustomRead(bio: *ssl.Bio, dst: []u8) c_int {
    var length = dst.len;
    const loop_ssl_data: *LoopSslData = @ptrCast(@alignCast(ssl.bioGetData(bio)));
    std.log.debug("bioSCustomRead", .{});
    if (loop_ssl_data.ssl_read_input_length == 0) {
        ssl.bioSetFlags(bio, ssl.c.BIO_FLAGS_SHOULD_RETRY | ssl.c.BIO_FLAGS_READ);
        return -1;
    }
    if (length > loop_ssl_data.ssl_read_input.len) length = loop_ssl_data.ssl_read_input_length;
    @memcpy(dst[0..length], loop_ssl_data.ssl_read_input[loop_ssl_data.ssl_read_input_offset..]);
    loop_ssl_data.ssl_read_input_offset += length;
    loop_ssl_data.ssl_read_input_length -= length;
    return @intCast(length);
}
