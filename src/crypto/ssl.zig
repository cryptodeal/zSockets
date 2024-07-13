const build_opts = @import("build_opts");
const constants = @import("../constants.zig");
const context = @import("../context.zig");
const internal = @import("../internal/internal.zig");
const sni = @import("sni_tree.zig");
const ssl = switch (build_opts.ssl_lib) {
    .openssl => @import("ssl/openssl.zig"),
    .wolfssl => @import("ssl/wolfssl.zig"),
    else => @import("ssl/boringssl.zig"), // default to boringssl
};
const std = @import("std");

const Loop = @import("../loop.zig").Loop;

const Allocator = std.mem.Allocator;
const LowPriorityState = internal.LowPriorityState;
const RECV_BUFFER_LENGTH = constants.RECV_BUFFER_LENGTH;
const RECV_BUFFER_PADDING = constants.RECV_BUFFER_PADDING;
const Socket = internal.Socket;
const SocketCtx = context.SocketCtx;
const SocketCtxOpts = context.SocketCtxOpts;

pub fn freeSslCtx(allocator: Allocator, ssl_ctx: ?*ssl.SSL_CTX) void {
    if (ssl_ctx) |ctx| {
        // if set, free password string
        if (ssl.SSL_CTX_get_default_passwd_cb_userdata(ctx)) |pwd| {
            allocator.free(std.mem.span(@as([*c]u8, @ptrCast(@alignCast(pwd)))));
        }
        ssl.SSL_CTX_free(ctx);
    }
}

// TODO(cryptodeal): purge c types in favor of zig primitives
pub const LoopSslData = struct {
    ssl_read_input: []u8,
    ssl_read_output: []u8,
    ssl_read_input_length: usize,
    ssl_read_input_offset: usize,
    ssl_socket: *Socket,
    last_write_was_msg_more: bool,
    msg_more: bool,
    shared_rbio: *ssl.BIO,
    shared_wbio: *ssl.BIO,
    shared_biom: *ssl.BIO_METHOD,
};

pub const SslError = error{
    None,
    Ssl,
    WantRead,
    WantWrite,
    WantX509Lookup,
    Syscall,
    ZeroReturn,
    WantConnect,
    WantAccept,
    WantChannelIdLookup,
    PendingSession,
    PendingCertificate,
    WantPrivateKeyOperation,
    PendingTicket,
    EarlyDataRejected,
    WantCertificateVerify,
    Handoff,
    Handback,
    WantRenegotiate,
    HandshakeHintsReady,
};

fn call(s: ?*ssl.SSL, ret_code: c_int) SslError!void {
    return switch (ssl.SSL_get_error(s, ret_code)) {
        ssl.SSL_ERROR_SSL => error.Ssl,
        ssl.SSL_ERROR_WANT_READ => error.WantRead,
        ssl.SSL_ERROR_WANT_WRITE => error.WantWrite,
        ssl.SSL_ERROR_WANT_X509_LOOKUP => error.WantX509Lookup,
        ssl.SSL_ERROR_SYSCALL => error.Syscall,
        ssl.SSL_ERROR_ZERO_RETURN => error.ZeroReturn,
        ssl.SSL_ERROR_WANT_CONNECT => error.WantConnect,
        ssl.SSL_ERROR_WANT_ACCEPT => error.WantAccept,
        ssl.SSL_ERROR_WANT_CHANNEL_ID_LOOKUP => error.WantChannelIdLookup,
        ssl.SSL_ERROR_PENDING_SESSION => error.PendingSession,
        ssl.SSL_ERROR_PENDING_CERTIFICATE => error.PendingCertificate,
        ssl.SSL_ERROR_WANT_PRIVATE_KEY_OPERATION => error.WantPrivateKeyOperation,
        ssl.SSL_ERROR_PENDING_TICKET => error.PendingTicket,
        ssl.SSL_ERROR_EARLY_DATA_REJECTED => error.EarlyDataRejected,
        ssl.SSL_ERROR_WANT_CERTIFICATE_VERIFY => error.WantCertificateVerify,
        ssl.SSL_ERROR_HANDOFF => error.Handoff,
        ssl.SSL_ERROR_HANDBACK => error.Handback,
        ssl.SSL_ERROR_WANT_RENEGOTIATE => error.WantRenegotiate,
        ssl.SSL_ERROR_HANDSHAKE_HINTS_READY => error.HandshakeHintsReady,
        else => {}, // void
    };
}

pub const InternalSslSocketCtx = struct {
    sc: SocketCtx,

    // this thing can be shared with other socket contexts via socket transfer!
    // maybe instead of holding once you hold many, a vector or set
    // when a socket that belongs to another socket context transfers to a new socket context
    ssl_ctx: ?*ssl.SSL_CTX,
    is_parent: bool,

    // TODO(cryptodeal): implement function pointers
    on_open: *const fn (s: *InternalSslSocket, is_client: bool, ip: []u8) *InternalSslSocket,
    on_data: *const fn (s: *InternalSslSocket, data: []u8) *InternalSslSocket,
    on_writable: *const fn (s: *InternalSslSocket) *InternalSslSocket,
    on_close: *const fn (s: *InternalSslSocket, code: i32, reason: ?*anyopaque) *InternalSslSocket,

    // Called for missing SNI hostnames, if not `null`
    on_server_name: ?*const fn (s: *InternalSslSocketCtx, hostname: []const u8) void,

    // Pointer to sni tree, created when the context is created and freed likewise when freed
    sni: *sni.SniNode,
};

// TODO:(cryptodeal): possible remove `s` field from below struct
// TODO:(cryptodeal): purge c types in favor of zig primitives
pub const InternalSslSocket = struct {
    s: Socket,
    ssl: ?*ssl.SSL,
    ssl_write_wants_read: bool,
    ssl_read_wants_write: bool,

    pub fn isShutdown(s: *InternalSslSocket) bool {
        return s.s.isShutdown(false) or (ssl.SSL_get_shutdown(s.ssl) & ssl.SSL_SENT_SHUTDOWN) == 1;
    }
};

pub fn passphraseCb(buf: [*c]u8, _: c_int, _: c_int, u: ?*anyopaque) callconv(.C) c_int {
    const passphrase: []const u8 = std.mem.span(@as([*c]u8, @ptrCast(@alignCast(u))));
    const buffer: []u8 = @as([*]u8, @ptrCast(@alignCast(buf)))[0..passphrase.len];
    @memcpy(buffer, passphrase);
    // put null at end? no?
    return @intCast(passphrase.len);
}

pub fn bioSCustomCreate(bio: [*c]ssl.BIO) callconv(.C) c_int {
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

pub fn bioSCustomCtrl(_: *ssl.BIO, cmd: BioCtrlType, _: c_long, _: ?*anyopaque) callconv(.C) c_long {
    return switch (cmd) {
        .flush => 1,
        else => 0,
    };
}

pub fn bioSCustomWrite(bio: [*c]ssl.BIO, data: [*c]const u8, len: c_int) callconv(.C) c_int {
    const loop_ssl_data: *LoopSslData = @ptrCast(@alignCast(ssl.BIO_get_data(bio)));
    std.log.debug("bioSCustomWrite", .{});
    loop_ssl_data.last_write_was_msg_more = loop_ssl_data.msg_more or len == 16413;
    const written = loop_ssl_data.ssl_socket.write(false, @as([*]const u8, @ptrCast(@alignCast(data)))[0..@intCast(len)], loop_ssl_data.last_write_was_msg_more) catch {
        ssl.BIO_set_flags(bio, ssl.BIO_FLAGS_SHOULD_RETRY | ssl.BIO_FLAGS_WRITE);
        return -1;
    };
    return @intCast(written);
}

pub fn bioSCustomRead(bio: *ssl.BIO, dst: [*c]u8, len: c_int) callconv(.C) c_int {
    var length: usize = @intCast(len);
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

pub fn internalSslSocketExt(s: *InternalSslSocket) ?*anyopaque {
    return @as([*]InternalSslSocket, @ptrCast(@alignCast(s))) + 1;
}

pub fn internalInitLoopSslData(allocator: Allocator, loop: *Loop) !void {
    if (loop.data.ssl_data == null) {
        const loop_ssl_data = try allocator.create(LoopSslData);
        errdefer allocator.destroy(loop_ssl_data);
        loop_ssl_data.ssl_read_output = try allocator.alloc(u8, RECV_BUFFER_LENGTH + RECV_BUFFER_PADDING * 2);
        errdefer allocator.free(loop_ssl_data.ssl_read_output);
        if (ssl.OPENSSL_init_ssl(0, null) != 1) return error.FailedInitSslData;
        loop_ssl_data.shared_biom = ssl.BIO_meth_new(ssl.BIO_TYPE_MEM, "zS BIO");
        if (ssl.BIO_meth_set_create(loop_ssl_data.shared_biom, bioSCustomCreate) == 1) return error.FailedSslBioMethCreate;
        if (ssl.BIO_meth_set_write(loop_ssl_data.shared_biom, bioSCustomWrite) == -1) return error.FailedSslBioMethWrite;
    }
}

fn sslIsLowPrio(s: *InternalSslSocket) LowPriorityState {
    return @enumFromInt(@as(u16, @intCast(ssl.SSL_in_init(s.ssl))));
}

pub fn internalCreateSslSocketCtx(allocator: Allocator, loop: *Loop, context_ext_size: usize, options: SocketCtxOpts) !*InternalSslSocketCtx {
    // initialize loop data (if not already initialized)
    try internalInitLoopSslData(allocator, loop);
    // attempt creating `SSL_CTX` from options
    const ssl_context: ?*ssl.SSL_CTX = try createSslCtxFromOpts(allocator, options);
    errdefer freeSslCtx(allocator, ssl_context);
    if (ssl_context == null) return error.FailedSslCtxInit;

    const ctx: *InternalSslSocketCtx = @ptrCast(@alignCast(try SocketCtx.init(allocator, false, loop, @sizeOf(InternalSslSocketCtx) + context_ext_size, options)));
    ctx.on_server_name = null;
    ctx.ssl_ctx = ssl_context;
    ctx.is_parent = true;
    ctx.sc.is_low_priority = @ptrCast(&sslIsLowPrio);
    _ = ssl.SSL_CTX_set_tlsext_servername_callback(ctx.ssl_ctx, &sniCb);
    _ = ssl.SSL_CTX_set_tlsext_servername_arg(ctx.ssl_ctx, ctx);
    ctx.sni = try allocator.create(sni.SniNode);
    ctx.sni.* = sni.SniNode.init(allocator);
    return ctx;
}

pub fn createSslCtxFromOpts(allocator: Allocator, options: SocketCtxOpts) !?*ssl.SSL_CTX {
    // create ssl context
    const ssl_context: ?*ssl.SSL_CTX = ssl.SSL_CTX_new(ssl.TLS_method());
    // default options (DO NOT CHANGE -- will break shit)
    _ = ssl.SSL_CTX_set_read_ahead(ssl_context, 1);
    _ = ssl.SSL_CTX_set_mode(ssl_context, ssl.SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER);

    // require minimum TLS 1.2
    if (ssl.SSL_CTX_set_min_proto_version(ssl_context, ssl.TLS1_2_VERSION) != 1) return error.FailedSslCtxInit;

    // below are helpers; can implement custom shit by using native
    // handle directly
    if (options.ssl_prefer_low_mem_usg) {
        _ = ssl.SSL_CTX_set_mode(ssl_context, ssl.SSL_MODE_RELEASE_BUFFERS);
    }

    if (options.passphrase) |passphrase| {
        // when freeing, we need to call `SSL_CTX_get_default_passwd_cb_userdata`
        // and free if set
        const p = try allocator.dupeZ(u8, passphrase); // dupe wouldn't copy null terminator
        ssl.SSL_CTX_set_default_passwd_cb_userdata(ssl_context, p.ptr);
        ssl.SSL_CTX_set_default_passwd_cb(ssl_context, passphraseCb);
    }

    if (options.cert_file_path) |cert_file_path| {
        if (ssl.SSL_CTX_use_certificate_chain_file(ssl_context, cert_file_path.ptr) != 1) {
            freeSslCtx(allocator, ssl_context);
            return error.CertChainFileError;
        }
    }

    if (options.key_file_path) |key_file_path| {
        if (ssl.SSL_CTX_use_PrivateKey_file(ssl_context, key_file_path.ptr, ssl.SSL_FILETYPE_PEM) != 1) {
            freeSslCtx(allocator, ssl_context);
            return error.PrivateKeyFileError;
        }
    }

    if (options.ca_file_path) |ca_file_path| {
        const ca_list: ?*ssl.struct_stack_st_X509_NAME = ssl.SSL_load_client_CA_file(ca_file_path.ptr);
        if (ca_list == null) {
            freeSslCtx(allocator, ssl_context);
            return error.CaFileError;
        }
        ssl.SSL_CTX_set_client_CA_list(ssl_context, ca_list);
        if (ssl.SSL_CTX_load_verify_locations(ssl_context, ca_file_path.ptr, null) != 1) {
            freeSslCtx(allocator, ssl_context);
            return error.CaFileError;
        }
        ssl.SSL_CTX_set_verify(ssl_context, ssl.SSL_VERIFY_PEER, null);
    }

    if (options.dh_params_file_path) |dh_params_file_path| {
        var dh_2048: ?*ssl.DH = null;
        if (std.c.fopen(dh_params_file_path.ptr, "r")) |dh_file| {
            defer _ = std.c.fclose(dh_file);
            dh_2048 = ssl.PEM_read_DHparams(@ptrCast(@alignCast(dh_file)), null, null, null);
        } else {
            freeSslCtx(allocator, ssl_context);
            return error.DhParamsFileError;
        }
        if (dh_2048 == null) {
            freeSslCtx(allocator, ssl_context);
            return error.DhParamsFileError;
        }
        const set_tmp_dh = ssl.SSL_CTX_set_tmp_dh(ssl_context, dh_2048);
        ssl.DH_free(dh_2048);
        if (set_tmp_dh != 1) {
            freeSslCtx(allocator, ssl_context);
            return error.DhParamsFileError;
        }

        // OWASP Cipher String 'A+' (https://www.owasp.org/index.php/TLS_Cipher_String_Cheat_Sheet)
        const cipher = "DHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256";
        if (ssl.SSL_CTX_set_cipher_list(ssl_context, cipher) != 1) {
            freeSslCtx(allocator, ssl_context);
            return error.SetCipherListError;
        }
    }

    if (options.ssl_ciphers) |ssl_ciphers| {
        if (ssl.SSL_CTX_set_cipher_list(ssl_context, ssl_ciphers.ptr) != 1) {
            freeSslCtx(allocator, ssl_context);
            return error.SetCipherListError;
        }
    }

    // must free this via `freeSslCtx`
    return ssl_context;
}

pub fn internalSslSocketWrite(s: *InternalSslSocket, data: []const u8, msg_more: bool) !usize {
    if (s.s.isClosed(false) or s.isShutdown()) return 0;
    const ctx: *InternalSslSocketCtx = @ptrCast(@alignCast(s.s.socketCtx(false)));
    const loop: *Loop = ctx.sc.socketCtxLoop(false);
    const loop_ssl_data: *LoopSslData = @ptrCast(@alignCast(loop.data.ssl_data));

    // TODO(cryptodeal): this should start at 0 and
    // only be reset by the `onData` cb
    loop_ssl_data.ssl_read_input_length = 0;

    loop_ssl_data.ssl_socket = &s.s;
    loop_ssl_data.msg_more = msg_more;
    loop_ssl_data.last_write_was_msg_more = false;
    std.debug.print("calling `sslWrite`", .{});
    const written = ssl.SSL_write(s.ssl, data.ptr, @intCast(data.len));
    std.debug.print("returning from `sslWrite`", .{});
    loop_ssl_data.msg_more = false;
    if (loop_ssl_data.last_write_was_msg_more and !msg_more) try s.s.flush(false);
    if (written > 0) {
        return @intCast(written);
    } else {
        const err = ssl.SSL_get_error(s.ssl, written);
        if (err == ssl.SSL_ERROR_WANT_READ) {
            // trigger writable event on next `ssl_read`
            s.ssl_write_wants_read = true;
        } else if (err == ssl.SSL_ERROR_SSL or err == ssl.SSL_ERROR_SYSCALL) {
            // these errors may add to the error queue (per-thread)
            // so we need to clear them
            ssl.ERR_clear_error();
        }
        return 0;
    }
}

pub fn resolveContext(ctx: *InternalSslSocketCtx, hostname: []const u8) ?*ssl.SSL_CTX {
    var user = sni.sniFind(ctx.sni, hostname);
    if (user) |u| return @ptrCast(@alignCast(u));
    if (ctx.on_server_name) |cb| {
        cb(ctx, hostname);
        user = sni.sniFind(ctx.sni, hostname);
    } else return null;
    return @ptrCast(@alignCast(user));
}

fn sniCb(ssl_: ?*ssl.SSL, _: [*c]c_int, arg: ?*anyopaque) callconv(.C) c_int {
    if (ssl_) |s| {
        const tmp_hostname: [*c]const u8 = ssl.SSL_get_servername(s, ssl.TLSEXT_NAMETYPE_host_name);
        if (tmp_hostname != null) {
            const hostname: []const u8 = std.mem.span(tmp_hostname);
            if (resolveContext(@ptrCast(@alignCast(arg)), hostname)) |resolved_ssl_context| {
                _ = ssl.SSL_set_SSL_CTX(ssl_, resolved_ssl_context);
            } else {
                // TODO: Call a blocking callback notifying of missing context???
            }
        }
        return ssl.SSL_TLSEXT_ERR_OK;
    } else return ssl.SSL_TLSEXT_ERR_NOACK;
}
