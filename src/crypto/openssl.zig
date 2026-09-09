const build_opts = @import("build_opts");
const ssl = switch (build_opts.ssl_impl) {
    .boringssl, .openssl => @import("openssl"),
    else => @compileError("Currently support only OpenSSL"),
};
const loop_ = @import("../loop.zig");
const std = @import("std");
const internal = @import("../internal/internal.zig");
const Extension = @import("../extension.zig");
const Loop = @import("../eventing/impl.zig").Loop;
const ListenSocket = @import("../listen_socket.zig");
const constants = @import("../internal/constants.zig");
const Socket = @import("../socket.zig");
const SocketContext = @import("../socket_context.zig");
const SocketContextOptions = @import("../socket_context_options.zig");
const sni_tree = @import("sni_tree.zig");

pub const LoopSslData = struct {
    ssl_read_input: [*]u8 = undefined,
    ssl_read_output: [*]u8 = undefined,
    ssl_read_input_length: usize = undefined,
    ssl_read_input_offset: usize = undefined,
    ssl_socket: *Socket = undefined,
    last_write_was_msg_more: bool = undefined,
    msg_more: bool = undefined,
    shared_rbio: ?*ssl.BIO = null,
    shared_wbio: ?*ssl.BIO = null,
    shared_biom: ?*ssl.BIO_METHOD = null,

    pub fn init(allocator: std.mem.Allocator) !*LoopSslData {
        const self = try allocator.create(LoopSslData);
        errdefer allocator.destroy(self);
        _ = ssl.OPENSSL_init_ssl(0, null);
        const read_output = try allocator.alloc(u8, constants.recv_buffer_length + constants.recv_buffer_padding * 2);
        errdefer allocator.free(read_output);
        self.* = .{
            .ssl_read_output = read_output.ptr,
            .shared_biom = ssl.BIO_meth_new(ssl.BIO_TYPE_MEM, "zS BIO"),
        };
        _ = ssl.BIO_meth_set_create(self.shared_biom, BioS.customCreate);
        _ = ssl.BIO_meth_set_write(self.shared_biom, BioS.customWrite);
        _ = ssl.BIO_meth_set_read(self.shared_biom, BioS.customRead);
        _ = ssl.BIO_meth_set_ctrl(self.shared_biom, BioS.customCtrl);
        self.shared_rbio = ssl.BIO_new(self.shared_biom);
        self.shared_wbio = ssl.BIO_new(self.shared_biom);
        ssl.BIO_set_data(self.shared_rbio, self);
        ssl.BIO_set_data(self.shared_wbio, self);
        return self;
    }

    pub fn deinit(self: *LoopSslData, allocator: std.mem.Allocator) void {
        const ssl_read_output: []u8 = self.ssl_read_output[0 .. constants.recv_buffer_length + constants.recv_buffer_padding * 2];
        allocator.free(ssl_read_output);
        _ = ssl.BIO_free(self.shared_rbio);
        _ = ssl.BIO_free(self.shared_wbio);
        _ = ssl.BIO_meth_free(self.shared_biom);
        allocator.destroy(self);
    }
};

pub const SslSocketContext = struct {
    sc: SocketContext = undefined,
    ssl_context: ?*ssl.SSL_CTX = null,
    is_parent: bool = false,
    on_open: *const fn (std.mem.Allocator, *SslSocket, bool, []u8) anyerror!*SslSocket = undefined,
    on_data: *const fn (std.mem.Allocator, *SslSocket, []u8) anyerror!*SslSocket = undefined,
    on_writable: *const fn (std.mem.Allocator, *SslSocket) anyerror!*SslSocket = undefined,
    on_close: *const fn (std.mem.Allocator, *SslSocket, i32, ?*anyopaque) anyerror!*SslSocket = undefined,
    // TODO: might need allocator/error
    on_server_name: ?*const fn (*SslSocketContext, []const u8) void = null,
    // TODO: might be able to type this more accurately
    sni: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator, loop: *Loop, options: SocketContextOptions, comptime MaybeT: ?type) !*SslSocketContext {
        try initLoopSslData(allocator, loop);
        const ssl_context = try createSslCtxFromOptions(allocator, options);
        if (ssl_context == null) {
            return error.SslContextCreationFailed;
        }
        const context = try allocator.create(SslSocketContext);
        context.* = .{
            .ssl_context = ssl_context,
            .is_parent = true,
        };
        try context.sc.internalInit(allocator, loop, options, MaybeT);
        context.sc.is_ssl = true;
        if (build_opts.ssl_impl == .openssl) {
            _ = ssl.SSL_CTX_callback_ctrl(context.ssl_context, ssl.SSL_CTRL_SET_TLSEXT_SERVERNAME_CB, @as(*fn () callconv(.c) void, @ptrCast(@alignCast(@constCast(&sniCb)))));
        } else if (build_opts.ssl_impl == .boringssl) {
            _ = ssl.SSL_CTX_set_tlsext_servername_callback(context.ssl_context, @ptrCast(@alignCast(&sniCb)));
        }
        _ = ssl.SSL_CTX_set_tlsext_servername_arg(context.ssl_context, context);
        context.sni = try sni_tree.SniNode.init(allocator);
        return context;
    }

    pub fn deinit(self: *SslSocketContext, allocator: std.mem.Allocator) void {
        if (self.is_parent) {
            freeSslCtx(allocator, self.ssl_context);
            sni_tree.sniFree(allocator, @ptrCast(@alignCast(self.sni)), sniHostnameDestructor);
        }
        loop_.loopUnlink(self.sc.loop, &self.sc);
        self.sc.ext.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn getNativeHandle(self: *SslSocketContext) ?*anyopaque {
        return self.ssl_context;
    }

    pub fn createChildContext(self: *SslSocketContext, allocator: std.mem.Allocator, comptime MaybeT: ?type) !*SslSocketContext {
        const child = try allocator.create(SslSocketContext);
        child.* = .{
            .ssl_context = self.ssl_context,
            .is_parent = false,
        };
        try child.sc.internalInit(allocator, self.sc.loop, .{}, MaybeT);
        child.sc.is_ssl = true;
        return child;
    }

    pub fn findServerNameUserdata(self: *SslSocketContext, hostname_pattern: [:0]const u8) ?*anyopaque {
        std.debug.print("finding {s}\n", .{hostname_pattern});
        const ssl_context: ?*ssl.SSL_CTX = @ptrCast(@alignCast(sni_tree.sniFind(@ptrCast(@alignCast(self.sni)), hostname_pattern)));
        if (ssl_context) |ctx| {
            return ssl.SSL_CTX_get_ex_data(ctx, 0);
        }
        return null;
    }

    pub fn addServerName(self: *SslSocketContext, allocator: std.mem.Allocator, hostname_pattern: [:0]const u8, options: SocketContextOptions, user: ?*anyopaque) !void {
        const ssl_context = try createSslCtxFromOptions(allocator, options);
        if (ssl_context) |ctx| {
            if (1 != ssl.SSL_CTX_set_ex_data(ctx, 0, user)) {
                std.debug.print("CANNOT SET EX DATA!\n", .{});
            }

            if (try sni_tree.sniAdd(allocator, @ptrCast(@alignCast(self.sni)), hostname_pattern, ssl_context)) {
                freeSslCtx(ssl_context);
            }
        }
    }

    pub fn setOnServerName(self: *SslSocketContext, cb: *const fn (*SslSocketContext, []const u8) void) void {
        self.on_server_name = cb;
    }

    pub fn removeServerName(self: *SslSocketContext, allocator: std.mem.Allocator, hostname_pattern: [:0]const u8) void {
        const sni_node_ssl_context: ?*ssl.SSL_CTX = @ptrCast(@alignCast(sni_tree.sniRemove(allocator, @ptrCast(@alignCast(self.sni)), hostname_pattern)));
        freeSslCtx(sni_node_ssl_context);
    }

    pub fn resolveContext(self: *SslSocketContext, hostname: [:0]const u8) ?*ssl.SSL_CTX {
        var user = sni_tree.sniFind(@ptrCast(@alignCast(self.sni)), hostname);
        if (user == null) {
            if (self.on_server_name == null) {
                return null;
            }

            self.on_server_name.?(self, hostname);

            user = sni_tree.sniFind(@ptrCast(@alignCast(self.sni)), hostname);
        }
        return @ptrCast(@alignCast(user));
    }

    pub fn listen(self: *SslSocketContext, allocator: std.mem.Allocator, host: ?[:0]const u8, port: u32, options: u32, comptime MaybeT: ?type) !*ListenSocket {
        return self.sc.listen(allocator, false, host, port, options, MaybeT);
    }

    pub fn listenUnix(self: *SslSocketContext, allocator: std.mem.Allocator, path: [:0]const u8, options: u32, comptime MaybeT: ?type) !*ListenSocket {
        return self.sc.listenUnix(allocator, false, path, options, MaybeT);
    }

    pub fn connect(self: *SslSocketContext, allocator: std.mem.Allocator, host: [:0]const u8, port: u32, source_host: ?[:0]const u8, options: u32, comptime MaybeT: ?type) !*SslSocket {
        const res = try allocator.create(SslSocket);
        try internal.connect(allocator, &self.sc, &res.s, host, port, source_host, options, MaybeT);
        res.s.is_ssl = true;
        return res;
    }

    pub fn connectUnix(self: *SslSocketContext, allocator: std.mem.Allocator, server_path: [:0]const u8, options: u32, comptime MaybeT: ?type) !*SslSocket {
        const res = try allocator.create(SslSocket);
        try internal.connectUnix(allocator, &self.sc, &res.s, server_path, options, MaybeT);
        res.s.is_ssl = true;
        return res;
    }

    pub fn setOnOpen(self: *SslSocketContext, cb: *const fn (std.mem.Allocator, *SslSocket, bool, []u8) anyerror!*SslSocket) void {
        self.sc.setOnOpen(false, @ptrCast(@alignCast(&sslOnOpen)));
        self.on_open = cb;
    }

    pub fn setOnClose(self: *SslSocketContext, cb: *const fn (std.mem.Allocator, *SslSocket, i32, ?*anyopaque) anyerror!*SslSocket) void {
        self.sc.setOnClose(false, @ptrCast(@alignCast(&sslOnClose)));
        self.on_close = cb;
    }

    pub fn setOnData(self: *SslSocketContext, cb: *const fn (std.mem.Allocator, *SslSocket, []u8) anyerror!*SslSocket) void {
        self.sc.setOnData(false, @ptrCast(@alignCast(&sslOnData)));
        self.on_data = cb;
    }

    pub fn setOnWritable(self: *SslSocketContext, cb: *const fn (std.mem.Allocator, *SslSocket) anyerror!*SslSocket) void {
        self.sc.setOnWritable(false, @ptrCast(@alignCast(&sslOnWritable)));
        self.on_writable = cb;
    }

    pub fn setOnTimeout(self: *SslSocketContext, cb: *const fn (std.mem.Allocator, *SslSocket) anyerror!*SslSocket) void {
        self.sc.setOnTimeout(false, @ptrCast(@alignCast(cb)));
    }

    pub fn setOnLongTimeout(self: *SslSocketContext, cb: *const fn (std.mem.Allocator, *SslSocket) anyerror!*SslSocket) void {
        self.sc.setOnLongTimeout(false, @ptrCast(@alignCast(cb)));
    }

    pub fn setOnEnd(self: *SslSocketContext, _: *const fn (std.mem.Allocator, *SslSocket) anyerror!*SslSocket) void {
        self.sc.setOnEnd(false, @ptrCast(@alignCast(&sslOnEnd)));
    }

    pub fn setOnConnectError(self: *SslSocketContext, cb: *const fn (std.mem.Allocator, *SslSocket, i32) anyerror!*SslSocket) void {
        self.sc.setOnConnectError(false, @ptrCast(@alignCast(cb)));
    }

    pub fn adoptSocket(self: *SslSocketContext, allocator: std.mem.Allocator, s: *SslSocket, comptime ExtensionT: ?type) !*SslSocket {
        _ = try self.sc.adoptSocket(allocator, false, &s.s, ExtensionT);
        return s;
    }
};

pub const SslSocket = struct {
    s: Socket,
    ssl: ?*ssl.SSL,
    ssl_write_wants_read: bool,
    ssl_read_wants_write: bool,

    pub fn close(self: *SslSocket, allocator: std.mem.Allocator, code: i32, reason: ?*anyopaque) !*SslSocket {
        return @fieldParentPtr("s", try self.s.close(allocator, false, code, reason));
    }

    pub fn isLowPriority(self: *SslSocket) bool {
        return ssl.SSL_in_init(self.ssl) != 0;
    }

    pub fn getSniUserdata(self: *SslSocket) ?*anyopaque {
        return ssl.SSL_CTX_get_ex_data(ssl.SSL_get_SSL_CTX(self.ssl), 0);
    }

    pub fn getNativeHandle(self: *SslSocket) ?*anyopaque {
        return self.ssl;
    }

    pub fn write(self: *SslSocket, data: []const u8, msg_more: bool) usize {
        if (self.s.isClosed(false) or self.isShutdown()) {
            return 0;
        }
        const context: *SslSocketContext = @fieldParentPtr("sc", self.s.context);
        const loop = context.sc.loop;
        const loop_ssl_data: *LoopSslData = @ptrCast(@alignCast(loop.data.ssl_data));
        loop_ssl_data.ssl_read_input_length = 0;
        loop_ssl_data.ssl_socket = &self.s;
        loop_ssl_data.msg_more = msg_more;
        loop_ssl_data.last_write_was_msg_more = false;
        const written = ssl.SSL_write(self.ssl, data.ptr, @intCast(data.len));
        loop_ssl_data.msg_more = false;
        if (loop_ssl_data.last_write_was_msg_more and !msg_more) {
            self.s.flush(false);
        }
        if (written > 0) {
            return @intCast(written);
        } else {
            const err = ssl.SSL_get_error(self.ssl, written);
            if (err == ssl.SSL_ERROR_WANT_READ) {
                self.ssl_write_wants_read = true;
            } else if (err == ssl.SSL_ERROR_SSL or err == ssl.SSL_ERROR_SYSCALL) {
                ssl.ERR_clear_error();
            }
            return 0;
        }
    }

    pub fn isShutdown(self: *SslSocket) bool {
        return self.s.isShutdown(false) or ssl.SSL_get_shutdown(self.ssl) & ssl.SSL_SENT_SHUTDOWN != 0;
    }

    pub fn shutdown(self: *SslSocket) void {
        if (!self.s.isClosed(false) and !self.isShutdown()) {
            const context: *SslSocketContext = @fieldParentPtr("sc", self.s.context);
            const loop = context.sc.loop;
            const loop_ssl_data: *LoopSslData = @ptrCast(@alignCast(loop.data.ssl_data));
            loop_ssl_data.ssl_read_input_length = 0;
            loop_ssl_data.ssl_socket = &self.s;
            loop_ssl_data.msg_more = false;
            var ret = ssl.SSL_shutdown(self.ssl);
            if (ret == 0) {
                ret = ssl.SSL_shutdown(self.ssl);
            }
            if (ret < 0) {
                const err = ssl.SSL_get_error(self.ssl, ret);
                if (err == ssl.SSL_ERROR_SSL or err == ssl.SSL_ERROR_SYSCALL) {
                    // clear
                    ssl.ERR_clear_error();
                }
                self.s.shutdown(false);
            }
        }
    }
};

fn passphraseCb(buf: [*c]u8, _: c_int, _: c_int, userdata: ?*anyopaque) callconv(.c) c_int {
    const passphrase = std.mem.span(@as([*c]u8, @ptrCast(@alignCast(userdata))));
    @memcpy(buf, passphrase);
    return @intCast(passphrase.len);
}

const BioS = struct {
    pub fn customCreate(bio: ?*ssl.BIO) callconv(.c) c_int {
        ssl.BIO_set_init(bio, 1);
        return 1;
    }

    pub fn customCtrl(_: ?*ssl.BIO, cmd: c_int, _: c_long, _: ?*anyopaque) callconv(.c) c_long {
        return switch (cmd) {
            ssl.BIO_CTRL_FLUSH => 1,
            else => 0,
        };
    }

    pub fn customWrite(bio: ?*ssl.BIO, data: [*c]const u8, length: c_int) callconv(.c) c_int {
        const loop_ssl_data = @as(?*LoopSslData, @ptrCast(@alignCast(ssl.BIO_get_data(bio)))).?;
        loop_ssl_data.last_write_was_msg_more = loop_ssl_data.msg_more or length == 16413;
        const written = loop_ssl_data.ssl_socket.write(false, @as([*]const u8, @ptrCast(@alignCast(data)))[0..@intCast(length)], loop_ssl_data.last_write_was_msg_more);
        if (written == 0) {
            ssl.BIO_set_flags(bio, ssl.BIO_FLAGS_SHOULD_RETRY | ssl.BIO_FLAGS_WRITE);
            return -1;
        }
        return @intCast(written);
    }

    pub fn customRead(bio: ?*ssl.BIO, dst: [*c]u8, length: c_int) callconv(.c) c_int {
        var length_: usize = @intCast(length);
        const loop_ssl_data = @as(?*LoopSslData, @ptrCast(@alignCast(ssl.BIO_get_data(bio)))).?;
        if (loop_ssl_data.ssl_read_input_length == 0) {
            ssl.BIO_set_flags(bio, ssl.BIO_FLAGS_SHOULD_RETRY | ssl.BIO_FLAGS_READ);
            return -1;
        }
        if (length_ > loop_ssl_data.ssl_read_input_length) {
            length_ = loop_ssl_data.ssl_read_input_length;
        }
        @memcpy(@as([*]u8, @ptrCast(@alignCast(dst))), loop_ssl_data.ssl_read_input[loop_ssl_data.ssl_read_input_offset .. loop_ssl_data.ssl_read_input_offset + length_]);
        loop_ssl_data.ssl_read_input_offset += length_;
        loop_ssl_data.ssl_read_input_length -= length_;
        return @intCast(length_);
    }
};

pub fn sslOnOpen(allocator: std.mem.Allocator, s: *SslSocket, is_client: bool, ip: []u8) !*SslSocket {
    const context: *SslSocketContext = @fieldParentPtr("sc", s.s.context);
    const loop = context.sc.loop;
    const loop_ssl_data: *LoopSslData = @ptrCast(@alignCast(loop.data.ssl_data));
    s.ssl = ssl.SSL_new(context.ssl_context);
    s.ssl_write_wants_read = false;
    s.ssl_read_wants_write = false;
    ssl.SSL_set_bio(s.ssl, loop_ssl_data.shared_rbio, loop_ssl_data.shared_wbio);
    _ = ssl.BIO_up_ref(loop_ssl_data.shared_rbio);
    _ = ssl.BIO_up_ref(loop_ssl_data.shared_wbio);
    if (is_client) {
        ssl.SSL_set_connect_state(s.ssl);
    } else {
        ssl.SSL_set_accept_state(s.ssl);
    }
    return context.on_open(allocator, s, is_client, ip);
}

pub fn sslOnClose(allocator: std.mem.Allocator, s: *SslSocket, code: i32, reason: ?*anyopaque) !*SslSocket {
    const context: *SslSocketContext = @fieldParentPtr("sc", s.s.context);
    ssl.SSL_free(s.ssl);
    return context.on_close(allocator, s, code, reason);
}

pub fn sslOnData(allocator: std.mem.Allocator, self: *SslSocket, data: []u8) !*SslSocket {
    var self_ = self;
    var context: *SslSocketContext = @fieldParentPtr("sc", self_.s.context);
    const loop = context.sc.loop;
    const loop_ssl_data: *LoopSslData = @ptrCast(@alignCast(loop.data.ssl_data));
    loop_ssl_data.ssl_read_input = data.ptr;
    loop_ssl_data.ssl_read_input_length = data.len;
    loop_ssl_data.ssl_read_input_offset = 0;
    loop_ssl_data.ssl_socket = &self_.s;
    loop_ssl_data.msg_more = false;
    if (self_.isShutdown()) {
        const ret = ssl.SSL_shutdown(self_.ssl);
        if (ret == 1) {
            return self_.close(allocator, 0, null);
        } else if (ret < 0) {
            const err = ssl.SSL_get_error(self_.ssl, ret);
            if (err == ssl.SSL_ERROR_SSL or err == ssl.SSL_ERROR_SYSCALL) {
                ssl.ERR_clear_error();
            }
        }
        return self_;
    }

    var read: c_int = 0;
    restart: while (true) {
        const just_read = ssl.SSL_read(self_.ssl, loop_ssl_data.ssl_read_output + constants.recv_buffer_padding + @as(usize, @intCast(read)), constants.recv_buffer_length - read);
        if (just_read <= 0) {
            const err = ssl.SSL_get_error(self_.ssl, just_read);
            if (err != ssl.SSL_ERROR_WANT_READ and err != ssl.SSL_ERROR_WANT_WRITE) {
                if (err == ssl.SSL_ERROR_SSL or err == ssl.SSL_ERROR_SYSCALL) {
                    ssl.ERR_clear_error();
                }
                return self_.close(allocator, 0, null);
            } else {
                if (err == ssl.SSL_ERROR_WANT_WRITE) {
                    self_.ssl_read_wants_write = true;
                }
                if (loop_ssl_data.ssl_read_input_length != 0) {
                    return self_.close(allocator, 0, null);
                }
                if (read == 0) {
                    break;
                }
                context = @fieldParentPtr("sc", self_.s.context);
                self_ = try context.on_data(allocator, self_, loop_ssl_data.ssl_read_output[constants.recv_buffer_padding..@intCast(constants.recv_buffer_padding + read)]);
                if (self_.s.isClosed(false)) {
                    return self_;
                }
                break;
            }
        }
        read += just_read;
        if (read == constants.recv_buffer_length) {
            context = @fieldParentPtr("sc", self_.s.context);
            self_ = try context.on_data(allocator, self_, loop_ssl_data.ssl_read_output[constants.recv_buffer_padding..@intCast(constants.recv_buffer_padding + read)]);
            if (self_.s.isClosed(false)) {
                return self_;
            }
            read = 0;
            continue :restart;
        }
    }

    if (self_.ssl_write_wants_read) {
        self_.ssl_write_wants_read = false;
        context = @fieldParentPtr("sc", self_.s.context);
        self_ = @fieldParentPtr("s", try context.sc.on_writable(allocator, &self_.s));
        if (self_.s.isClosed(false)) {
            return self_;
        }
    }

    if (ssl.SSL_get_shutdown(self_.ssl) & ssl.SSL_RECEIVED_SHUTDOWN != 0) {
        self_ = try self_.close(allocator, 0, null);
    }
    return self_;
}

pub fn sslOnWritable(allocator: std.mem.Allocator, self: *SslSocket) !*SslSocket {
    var self_ = self;
    var context: *SslSocketContext = @fieldParentPtr("sc", self_.s.context);
    if (self_.ssl_read_wants_write) {
        self_.ssl_read_wants_write = false;
        context = @fieldParentPtr("sc", self_.s.context);
        self_ = @fieldParentPtr("s", try context.sc.on_data(allocator, &self.s, &.{}));
    }
    self_ = try context.on_writable(allocator, self_);
    return self_;
}

pub fn sslOnEnd(allocator: std.mem.Allocator, self: *SslSocket) !*SslSocket {
    return self.close(allocator, 0, null);
}

pub fn initLoopSslData(allocator: std.mem.Allocator, loop: *Loop) !void {
    if (loop.data.ssl_data == null) {
        loop.data.ssl_data = try LoopSslData.init(allocator);
    }
}

pub fn freeLoopSslData(allocator: std.mem.Allocator, loop: *Loop) void {
    const loop_ssl_data: ?*LoopSslData = @ptrCast(@alignCast(loop.data.ssl_data));
    if (loop_ssl_data) |data| {
        data.deinit(allocator);
        loop.data.ssl_data = null;
    }
}

pub fn freeSslCtx(allocator: std.mem.Allocator, ssl_context: ?*ssl.SSL_CTX) void {
    if (ssl_context) |sc| {
        if (ssl.SSL_CTX_get_default_passwd_cb_userdata(sc)) |password| {
            const pw_str = std.mem.span(@as([*:0]u8, @ptrCast(@alignCast(password))));
            allocator.free(pw_str);
        }
        ssl.SSL_CTX_free(sc);
    }
}

pub fn createSslCtxFromOptions(allocator: std.mem.Allocator, options: SocketContextOptions) !?*ssl.SSL_CTX {
    const ssl_context = ssl.SSL_CTX_new(ssl.TLS_method());
    _ = ssl.SSL_CTX_set_read_ahead(ssl_context, 1);
    _ = ssl.SSL_CTX_set_mode(ssl_context, ssl.SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER);
    _ = ssl.SSL_CTX_set_min_proto_version(ssl_context, ssl.TLS1_2_VERSION);

    if (options.prefer_low_memory_usage) {
        _ = ssl.SSL_CTX_set_mode(ssl_context, ssl.SSL_MODE_RELEASE_BUFFERS);
    }

    if (options.passphrase.len != 0) {
        ssl.SSL_CTX_set_default_passwd_cb_userdata(ssl_context, (try allocator.dupeSentinel(u8, options.passphrase, 0)).ptr);
        ssl.SSL_CTX_set_default_passwd_cb(ssl_context, passphraseCb);
    }

    if (options.cert_file_name.len != 0) {
        if (ssl.SSL_CTX_use_certificate_chain_file(ssl_context, options.cert_file_name.ptr) != 1) {
            freeSslCtx(allocator, ssl_context);
            return null;
        }
    }

    if (options.key_file_name.len != 0) {
        if (ssl.SSL_CTX_use_PrivateKey_file(ssl_context, options.key_file_name.ptr, ssl.SSL_FILETYPE_PEM) != 1) {
            freeSslCtx(allocator, ssl_context);
            return null;
        }
    }

    if (options.ca_file_name.len != 0) {
        var ca_list: ?*ssl.struct_stack_st_X509_NAME = undefined;
        ca_list = ssl.SSL_load_client_CA_file(options.ca_file_name.ptr);
        if (ca_list == null) {
            freeSslCtx(allocator, ssl_context);
            return null;
        }
        ssl.SSL_CTX_set_client_CA_list(ssl_context, ca_list);
        if (ssl.SSL_CTX_load_verify_locations(ssl_context, options.ca_file_name.ptr, null) != 1) {
            freeSslCtx(allocator, ssl_context);
            return null;
        }
        ssl.SSL_CTX_set_verify(ssl_context, ssl.SSL_VERIFY_PEER, null);
    }

    if (options.dh_params_file_name.len != 0) {
        var dh_2048: ?*ssl.DH = null;
        var paramfile: ?*ssl.FILE = undefined;
        paramfile = ssl.fopen(options.dh_params_file_name.ptr, "r");

        if (paramfile) |_| {
            dh_2048 = ssl.PEM_read_DHparams(paramfile, null, null, null);
            _ = ssl.fclose(paramfile);
        } else {
            freeSslCtx(allocator, ssl_context);
            return null;
        }

        if (dh_2048 == null) {
            freeSslCtx(allocator, ssl_context);
            return null;
        }

        const set_tmp_dh: c_long = ssl.SSL_CTX_set_tmp_dh(ssl_context, dh_2048);
        ssl.DH_free(dh_2048);

        if (set_tmp_dh != 1) {
            freeSslCtx(allocator, ssl_context);
            return null;
        }

        if (ssl.SSL_CTX_set_cipher_list(ssl_context, "DHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256") != 1) {
            freeSslCtx(allocator, ssl_context);
            return null;
        }
    }

    if (options.ssl_ciphers.len != 0) {
        if (ssl.SSL_CTX_set_cipher_list(ssl_context, options.ssl_ciphers.ptr) != 1) {
            freeSslCtx(allocator, ssl_context);
            return null;
        }
    }

    return ssl_context;
}

fn sniCb(ssl_: ?*ssl.SSL, _: ?*c_int, arg: ?*anyopaque) callconv(.c) c_int {
    if (ssl_ != null) {
        const hostname = ssl.SSL_get_servername(ssl_, ssl.TLSEXT_NAMETYPE_host_name);
        // TODO: need to check if null char is only value
        if (hostname != null) {
            const resolved_ssl_context = @as(*SslSocketContext, @ptrCast(@alignCast(arg))).resolveContext(std.mem.span(hostname));
            if (resolved_ssl_context) |rsc| {
                _ = ssl.SSL_set_SSL_CTX(ssl_, rsc);
            } else {}
        }
        return ssl.SSL_TLSEXT_ERR_OK;
    }
    return ssl.SSL_TLSEXT_ERR_NOACK;
}

fn sniHostnameDestructor(allocator: std.mem.Allocator, user: ?*anyopaque) void {
    freeSslCtx(allocator, @as(?*ssl.SSL_CTX, @ptrCast(@alignCast(user))));
}

pub fn adoptAcceptedSocket(allocator: std.mem.Allocator, context: *SslSocketContext, accepted_fd: std.posix.fd_t, addr_ip: []u8, extension: Extension) !*SslSocket {
    const socket = try allocator.create(SslSocket);
    try internal.adoptAcceptedSocket(allocator, &socket.s, &context.sc, accepted_fd, addr_ip, extension);
    socket.s.is_ssl = true;
    return socket;
}
