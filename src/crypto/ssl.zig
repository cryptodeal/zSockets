const build_opts = @import("build_opts");
const internal = @import("../internal/internal.zig");
const ssl = if (build_opts.USE_OPENSSL) @import("ssl/openssl.zig") else if (build_opts.USE_WOLFSSL) @import("ssl/wolfssl.zig") else undefined;
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
    shared_rbio: *ssl.BIO,
    shared_wbio: *ssl.BIO,
    shared_biom: *ssl.BIO_METHOD,
};

pub const InternalSslSocketCtx = struct {
    // sc: SocketCtx,

    // this thing can be shared with other socket contexts via socket transfer!
    // maybe instead of holding once you hold many, a vector or set
    // when a socket that belongs to another socket context transfers to a new socket context
    ssl_ctx: *ssl.SSL_CTX,
    is_parent: bool,

    // TODO(cryptodeal): implement function pointers
    on_open: *const fn (s: *InternalSslSocket, is_client: bool, ip: []u8) *InternalSslSocket,
    on_data: *const fn (s: *InternalSslSocket, data: []u8) *InternalSslSocket,
    on_writable: *const fn (s: *InternalSslSocket) *InternalSslSocket,
    on_close: *const fn (s: *InternalSslSocket, code: i32, reason: ?*anyopaque) *InternalSslSocket,

    // Called for missing SNI hostnames, if not `null`
    on_server_name: *const fn (s: *InternalSslSocketCtx, hostname: []const u8) void,

    // Pointer to sni tree, created when the context is created and freed likewise when freed
    sni: ?*anyopaque,
};

// TODO:(cryptodeal): possible remove `s` field from below struct
// TODO:(cryptodeal): purge c types in favor of zig primitives
pub const InternalSslSocket = struct {
    s: Socket,
    ssl: *ssl.SSL,
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

pub fn bioSCustomCreate(bio: *ssl.BIO) c_int {
    ssl.BIO_set_init(bio, 1);
    return 1;
}

pub const BioCtrlType = enum(c_int) {
    reset = ssl.BIO_CTRL_RESET,
    eof = ssl.BIO_CTRL_EOF,
    info = ssl.BIO_CTRL_INFO,
    set = ssl.BIO_CTRL_SET,
    get = ssl.BIO_CTRL_GET,
    push = ssl.BIO_CTRL_PUSH,
    pop = ssl.BIO_CTRL_POP,
    get_close = ssl.BIO_CTRL_GET_CLOSE,
    set_close = ssl.BIO_CTRL_SET_CLOSE,
    pending = ssl.BIO_CTRL_PENDING,
    flush = ssl.BIO_CTRL_FLUSH,
    dup = ssl.BIO_CTRL_DUP,
    wpending = ssl.BIO_CTRL_WPENDING,
};

pub fn bioSCustomCtrl(bio: *ssl.BIO, cmd: BioCtrlType, num: c_long, user: ?*anyopaque) c_long {
    _ = bio; // autofix
    _ = num; // autofix
    _ = user; // autofix
    return switch (cmd) {
        .flush => 1,
        else => 0,
    };
}

// TODO(cryptodeal): finish implementing
// pub fn bioSCustomWrite(bio: *ssl.BIO, data: []const u8) c_int {
//     const loop_ssl_data: *LoopSslData = @ptrCast(@alignCast(ssl.BIO_get_data(bio)));
//     std.log.debug("bioSCustomWrite", .{});
//     loop_ssl_data.last_write_was_msg_more = loop_ssl_data.msg_more or data.len == 16413;
// }

pub fn bioSCustomRead(bio: *ssl.BIO, dst: []u8) c_int {
    var length = dst.len;
    const loop_ssl_data: *LoopSslData = @ptrCast(@alignCast(ssl.BIO_get_data(bio)));
    std.log.debug("bioSCustomRead", .{});
    if (loop_ssl_data.ssl_read_input_length == 0) {
        ssl.BIO_set_flags(bio, ssl.BIO_FLAGS_SHOULD_RETRY | ssl.BIO_FLAGS_READ);
        return -1;
    }
    if (length > loop_ssl_data.ssl_read_input.len) length = loop_ssl_data.ssl_read_input_length;
    @memcpy(dst[0..length], loop_ssl_data.ssl_read_input[loop_ssl_data.ssl_read_input_offset..]);
    loop_ssl_data.ssl_read_input_offset += length;
    loop_ssl_data.ssl_read_input_length -= length;
    return @intCast(length);
}

// TODO(cryptodeal): finish implementing
// pub fn sslOnOpen(s: *InternalSslSocket, is_client: bool, ip: []u8) *InternalSslSocket {
//     _ = s; // autofix
//     _ = is_client; // autofix
//     _ = ip; // autofix
//     // const ctx: *InternalSslSocketCtx = @ptrCast(@alignCast(socketContext(0, &s.s)));
// }
